module SpreePaypalCheckout
  # Service object responsible for finalizing a PayPal transaction by capturing
  # the authorized funds and synchronizing the order state within Spree.
  class CaptureOrder
    # @param paypal_order [SpreePaypalCheckout::Order] The local record tracking the PayPal transaction
    def initialize(paypal_order:)
      @paypal_order = paypal_order
      @order = paypal_order.order
      @gateway = paypal_order.gateway
      @amount = paypal_order.amount
    end

    attr_reader :paypal_order, :order, :gateway, :amount

    # Executes the capture process.
    # Returns the updated SpreePaypalCheckout::Order record.
    def call
      # Prevent duplicate captures if the order is already finalized or canceled
      return paypal_order if order.completed? || order.canceled?

      # Trigger the PayPal API capture call via the gateway
      # Amounts are converted to cents as required by standard gateway interfaces
      gateway_response = gateway.capture(
        Money.new(amount, order.currency).cents,
        paypal_order.paypal_id,
        {
          order_id: order.number
        }
      )

      # Wrap state changes in a database lock to prevent race conditions during
      # concurrent API callbacks or user actions
      order.with_lock do
        # Persist the full JSON response from PayPal for auditing and debugging
        paypal_order.update!(data: gateway_response.params)

        # Synchronize email and address data from PayPal back to the Spree order
        add_customer_information(order, paypal_order.data)

        # Generate the Spree::Payment record to reflect the successful transaction
        paypal_order.create_payment!

        # Transition the Spree order to the 'complete' state and trigger
        # standard post-checkout logic (emails, inventory adjustments, etc.)
        Spree::Dependencies.checkout_complete_service.constantize.call(order: order)
      end

      paypal_order
    end

    private

    # Handles data synchronization for "Quick Checkout" or guest flows where
    # the user's information is mastered in PayPal rather than on the site.
    # @param order [Spree::Order]
    # @param paypal_data [Hash] The raw JSON data returned from the PayPal Capture API
    def add_customer_information(order, paypal_data)
      payer = paypal_data['payer']

      # Determine the best available address from the PayPal response.
      # Preference: Shipping Address -> Payer's Profile Address.
      paypal_address = paypal_data.dig('purchase_units', 0, 'shipping', 'address') || payer.dig('address')

      return unless paypal_address

      # Update order email if it hasn't been set yet
      order.email ||= payer['email_address']

      # Skip address population if the order already has a valid billing address
      return if order.bill_address.present? && order.bill_address.valid?

      # Resolve the correct Spree::Country record based on the ISO code provided by PayPal
      country = Spree::Country.find_by(iso: paypal_address['country_code']) || Spree::Country.default

      # Initialize or find the billing address for the order
      order.bill_address ||= Spree::Address.new(country: country, user: order.user)
      order.bill_address.attributes = {
        firstname: payer.dig('name', 'given_name') || 'PayPal',
        lastname: payer.dig('name', 'surname') || 'User',
        address1: paypal_address['address_line_1'],
        address2: paypal_address['address_line_2'],
        city: paypal_address['admin_area_2'],
        zipcode: paypal_address['postal_code'],
        # Fallback to the shipping phone number if PayPal doesn't provide one
        phone: order.ship_address&.phone || '0000000000'
      }

      # Resolution logic for States/Provinces (admin_area_1 in PayPal schema)
      state_code = paypal_address['admin_area_1']
      if state_code.present?
        # Attempt to match by abbreviation first, then by full name
        state = country.states.find_by(abbr: state_code) || country.states.find_by(name: state_code)
        if state
          order.bill_address.state = state
        else
          # Fallback for regions not formally defined in the Spree database
          order.bill_address.state_name = state_code
        end
      end

      # Persist the finalized address and order updates
      order.bill_address.save!
      order.save!
    end

    # Helper to sync the finalized checkout information back to the user's permanent profile.
    def copy_bill_info_to_user(order)
      user = order.user
      return unless user

      user.first_name ||= order.bill_address.first_name
      user.last_name ||= order.bill_address.last_name
      user.phone ||= order.bill_address.phone
      user.bill_address_id ||= order.bill_address.id
      user.save! if user.changed?
    end
  end
end
