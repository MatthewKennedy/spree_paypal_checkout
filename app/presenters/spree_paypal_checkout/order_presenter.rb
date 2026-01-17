require 'paypal_server_sdk'

module SpreePaypalCheckout
  # This presenter is responsible for transforming a Spree::Order object into the
  # JSON structure required by the PayPal V2 Orders API. It acts as a
  # translation layer between Spree's data models and the paypal-server-sdk.
  class OrderPresenter
    include PaypalServerSdk

    # PayPal enforces a strict 127-character limit on item names.
    PAYPAL_ITEM_NAME_MAX_LENGTH = 127

    def initialize(order)
      @order = order
    end

    attr_reader :order

    # Generates the hash structure expected by the PayPal SDK's create_order method.
    # @return [Hash] A hash containing the :body key with a populated OrderRequest object.
    def to_json
      # Determine the primary address to use for the transaction.
      # We prefer the billing address but fallback to shipping if billing is absent.
      source_address = order.bill_address || order.ship_address
      paypal_wallet_options = {}

      # Prepare the billing address if a valid source exists.
      if source_address.present?
        # Note: The PaypalWallet model uses the :address key for billing info.
        paypal_wallet_options[:address] = Address.new(
          address_line_1: source_address.address1,
          address_line_2: source_address.address2,
          admin_area_2: source_address.city,
          # .presence is crucial here; PayPal rejects empty strings for state codes.
          # It ensures countries without states (like the UK) send nil instead of "".
          admin_area_1: (source_address.state&.abbr || source_address.state_name).presence,
          postal_code: source_address.zipcode,
          country_code: source_address.country.iso
        )
      end

      {
        'body' => OrderRequest.new(
          # CAPTURE intent indicates we want to settle the payment immediately.
          intent: CheckoutPaymentIntent::CAPTURE,

          # payment_source configures the 'wallet' experience and provides billing details.
          payment_source: PaymentSource.new(
            paypal: PaypalWallet.new(**paypal_wallet_options)
          ),

          # application_context controls the user experience on the PayPal checkout page.
          application_context: OrderApplicationContext.new(
            # 'SET_PROVIDED_ADDRESS' prevents users from changing the shipping address on PayPal.
            shipping_preference: order.ship_address.present? ? 'SET_PROVIDED_ADDRESS' : 'GET_FROM_FILE',
            # 'PAY_NOW' sets the final button text to "Pay Now" instead of "Continue".
            user_action: 'PAY_NOW'
          ),

          # purchase_units represents the 'invoice'—the actual goods and totals.
          purchase_units: [
            PurchaseUnitRequest.new(
              amount: AmountWithBreakdown.new(
                currency_code: order.currency.upcase,
                value: order.total.to_s,
                # The breakdown must mathematically sum up to the total 'value' above.
                breakdown: AmountBreakdown.new(
                  item_total: Money.new(currency_code: order.currency.upcase, value: order.item_total.to_s),
                  shipping: Money.new(currency_code: order.currency.upcase, value: order.ship_total.to_s),
                  tax_total: Money.new(currency_code: order.currency.upcase, value: order.additional_tax_total.to_s),
                  discount: Money.new(currency_code: order.currency.upcase, value: order.promo_total.abs.to_s)
                )
              ),

              # Map Spree Line Items to PayPal Items.
              items: order.line_items.map do |line_item|
                Item.new(
                  # Truncate names to avoid 400 errors from schema violations.
                  name: (line_item.name || "").to_s[0...PAYPAL_ITEM_NAME_MAX_LENGTH],
                  unit_amount: Money.new(currency_code: order.currency.upcase, value: line_item.price.to_s),
                  quantity: line_item.quantity.to_s,
                  sku: line_item.sku,
                  # Distinguish between physical and digital goods for tax/shipping logic.
                  category: line_item.variant.digital? ? ItemCategory::DIGITAL_GOODS : ItemCategory::PHYSICAL_GOODS
                )
              end,

              # Include shipping details only if an address has been selected in Spree.
              shipping: order.ship_address.present? ? ShippingDetails.new(
                name: ShippingName.new(full_name: order.ship_address.full_name),
                address: Address.new(
                  address_line_1: order.ship_address.address1,
                  address_line_2: order.ship_address.address2,
                  admin_area_2: order.ship_address.city,
                  admin_area_1: (order.ship_address.state&.abbr || order.ship_address.state_name).presence,
                  postal_code: order.ship_address.zipcode,
                  country_code: order.ship_address.country.iso
                )
              ) : nil
            )
          ]
        )
      }
    end
  end
end
