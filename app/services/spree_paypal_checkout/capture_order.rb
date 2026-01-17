module SpreePaypalCheckout
  class CaptureOrder
    def initialize(paypal_order:)
      @paypal_order = paypal_order
      @order = paypal_order.order
      @gateway = paypal_order.gateway
      @amount = paypal_order.amount
    end

    attr_reader :paypal_order, :order, :gateway, :amount

    def call
      return paypal_order if order.completed? || order.canceled?

      # capture the order in PayPal API
      gateway_response = gateway.capture(
        Money.new(amount, order.currency).cents,
        paypal_order.paypal_id,
        {
          order_id: order.number
        }
      )

      order.with_lock do
        # gateway_response.params is a JSON response from PayPal APIs
        paypal_order.update!(data: gateway_response.params)

        add_customer_information(order, paypal_order.data)

        # create the Spree::Payment record
        paypal_order.create_payment!

        # complete the order in Spree
        Spree::Dependencies.checkout_complete_service.constantize.call(order: order)
      end

      paypal_order
    end

    private

    # we need to perform this for quick checkout orders which do not have these fields filled
    def add_customer_information(order, paypal_data)
      payer = paypal_data['payer']
      # Use shipping address as a fallback for billing if not explicitly provided
      paypal_address = paypal_data.dig('purchase_units', 0, 'shipping', 'address') || payer.dig('address')

      return unless paypal_address

      order.email ||= payer['email_address']

      # Only populate if the order doesn't already have a valid billing address
      return if order.bill_address.present? && order.bill_address.valid?

      country = Spree::Country.find_by(iso: paypal_address['country_code']) || Spree::Country.default

      order.bill_address ||= Spree::Address.new(country: country, user: order.user)
      order.bill_address.attributes = {
        firstname: payer.dig('name', 'given_name') || 'PayPal',
        lastname: payer.dig('name', 'surname') || 'User',
        address1: paypal_address['address_line_1'],
        address2: paypal_address['address_line_2'],
        city: paypal_address['admin_area_2'],
        zipcode: paypal_address['postal_code'],
        phone: order.ship_address&.phone || '0000000000' # PayPal doesn't always return phone
      }

      # Handle state/province
      state_code = paypal_address['admin_area_1']
      if state_code.present?
        state = country.states.find_by(abbr: state_code) || country.states.find_by(name: state_code)
        if state
          order.bill_address.state = state
        else
          order.bill_address.state_name = state_code
        end
      end

      order.bill_address.save!
      order.save!
    end

    def copy_bill_info_to_user(order)
      user = order.user
      user.first_name ||= order.bill_address.first_name
      user.last_name ||= order.bill_address.last_name
      user.phone ||= order.bill_address.phone
      user.bill_address_id ||= order.bill_address.id
      user.save! if user.changed?
    end
  end
end
