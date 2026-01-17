require 'paypal_server_sdk'

module SpreePaypalCheckout
  class OrderPresenter
    include PaypalServerSdk

    PAYPAL_ITEM_NAME_MAX_LENGTH = 127

    def initialize(order)
      @order = order
    end

    attr_reader :order

    def to_json
      source_address = order.bill_address || order.ship_address
        paypal_wallet_options = {}

      if source_address.present?
        paypal_wallet_options[:address] = Address.new(
          address_line_1: source_address.address1,
          address_line_2: source_address.address2,
          admin_area_2: source_address.city,
          admin_area_1: (source_address.state&.abbr || source_address.state_name).presence,
          postal_code: source_address.zipcode,
          country_code: source_address.country.iso
        )
      end

      {
        'body' => OrderRequest.new(
          intent: CheckoutPaymentIntent::CAPTURE,
          payment_source: PaymentSource.new(
            paypal: PaypalWallet.new(**paypal_wallet_options)
          ),
          application_context: OrderApplicationContext.new(
            shipping_preference: order.ship_address.present? ? 'SET_PROVIDED_ADDRESS' : 'GET_FROM_FILE',
            user_action: 'PAY_NOW'
          ),
          purchase_units: [
            PurchaseUnitRequest.new(
              amount: AmountWithBreakdown.new(
                currency_code: order.currency.upcase,
                value: order.total.to_s,
                breakdown: AmountBreakdown.new(
                  item_total: Money.new(currency_code: order.currency.upcase, value: order.item_total.to_s),
                  shipping: Money.new(currency_code: order.currency.upcase, value: order.ship_total.to_s),
                  tax_total: Money.new(currency_code: order.currency.upcase, value: order.additional_tax_total.to_s),
                  discount: Money.new(currency_code: order.currency.upcase, value: order.promo_total.abs.to_s)
                )
              ),
              items: order.line_items.map do |line_item|
                Item.new(
                  name: (line_item.name || "").to_s[0...PAYPAL_ITEM_NAME_MAX_LENGTH],
                  unit_amount: Money.new(currency_code: order.currency.upcase, value: line_item.price.to_s),
                  quantity: line_item.quantity.to_s,
                  sku: line_item.sku,
                  category: line_item.variant.digital? ? ItemCategory::DIGITAL_GOODS : ItemCategory::PHYSICAL_GOODS
                )
              end,
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
