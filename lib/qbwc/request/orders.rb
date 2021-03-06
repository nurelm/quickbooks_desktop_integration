module QBWC
  module Request
    class Orders
      class << self
        def generate_request_queries(objects, params)
          objects.inject('') do |request, object|
            sanitize_order(object)

            # Needed to keep shipment ID b/c and Order already has a order_id
            extra = "shipment-#{object['order_id']}-" if object.key?('shipment_id')
            config = { connection_id: params['connection_id'] }.with_indifferent_access
            session_id = Persistence::Session.save(config, object, extra)

            request << search_xml(object['id'], session_id)
          end
        end

        def generate_request_insert_update(objects, params = {})
          objects.inject('') do |request, object|
            sanitize_order(object)

            config = { connection_id: params['connection_id'] }.with_indifferent_access
            session_id = Persistence::Session.save(config, object)

            request << if object[:list_id].to_s.empty?
                         add_xml_to_send(object, params, session_id)
                       else
                         update_xml_to_send(object, params, session_id)
                      end
          end
        end

        def search_xml(order_id, session_id)
          <<-XML
<SalesOrderQueryRq requestID="#{session_id}">
  <RefNumberCaseSensitive>#{order_id}</RefNumberCaseSensitive>
  <IncludeLineItems>true</IncludeLineItems>
</SalesOrderQueryRq>
          XML
        end

        def add_xml_to_send(record, params= {}, session_id)
          <<-XML

<SalesOrderAddRq requestID="#{session_id}">
  <SalesOrderAdd>
    #{sales_order record, params}
    #{items(record).map { |l| sales_order_line_add l }.join('')}
    #{adjustments(record).map { |l| sales_order_line_add_from_adjustment(l, params) }.join('')}
  </SalesOrderAdd>
</SalesOrderAddRq>
          XML
        end

        def update_xml_to_send(record, params= {}, session_id)
          <<-XML

<SalesOrderModRq requestID="#{session_id}">
  <SalesOrderMod>
    <TxnID>#{record['list_id']}</TxnID>
    <EditSequence>#{record['edit_sequence']}</EditSequence>
    #{sales_order record, params}
    #{items(record).map { |l| sales_order_line_mod l }.join('')}
    #{adjustments(record).map { |l| sales_order_line_adjustment_mod(l, params) }.join('')}
  </SalesOrderMod>
</SalesOrderModRq>
          XML
        end

        # NOTE Brave soul needed to find a lib or build one from scratch to
        # map this xml mess to proper ruby objects with a to_xml method

        # The order of tags here matter. e.g. PONumber MUST be after
        # ship address or you end up getting:
        #
        #   QuickBooks found an error when parsing the provided XML text stream.
        #
        # View sales_order_add_rq.xml in case you need to look into add more
        # tags to this request
        #
        # View sales_order_add_rs_invalid_record_ref.xml to see what'd you
        # get by sending a invalid Customer Ref you'd get as a response.
        #
        # 'placed_on' needs to be a valid date string otherwise an exception
        # will be raised
        #
        def sales_order(record, _params)
          <<-XML

    <CustomerRef>
      <FullName>#{record['email']}</FullName>
    </CustomerRef>
    <TxnDate>#{Time.parse(record['placed_on']).to_date}</TxnDate>
    <RefNumber>#{record['id']}</RefNumber>
    <BillAddress>
      <Addr1>#{record['billing_address']['address1']}</Addr1>
      <Addr2>#{record['billing_address']['address2']}</Addr2>
      <City>#{record['billing_address']['city']}</City>
      <State>#{record['billing_address']['state']}</State>
      <PostalCode>#{record['billing_address']['zipcode']}</PostalCode>
      <Country>#{record['billing_address']['country']}</Country>
    </BillAddress>
    <ShipAddress>
      <Addr1>#{record['shipping_address']['address1']}</Addr1>
      <Addr2>#{record['shipping_address']['address2']}</Addr2>
      <City>#{record['shipping_address']['city']}</City>
      <State>#{record['shipping_address']['state']}</State>
      <PostalCode>#{record['shipping_address']['zipcode']}</PostalCode>
      <Country>#{record['shipping_address']['country']}</Country>
    </ShipAddress>
    #{cancel_order?(record)}
          XML
        end

        def sales_order_line_add(line)
          <<-XML

    <SalesOrderLineAdd>
      #{sales_order_line(line)}
    </SalesOrderLineAdd>
          XML
        end

        def sales_order_line_add_from_adjustment(adjustment, params)
          line = {
            'product_id' => QBWC::Request::Adjustments.adjustment_product_from_qb(adjustment['name'], params),
            'quantity' => 0,
            'price' => adjustment['value']
          }

          sales_order_line_add line
        end

        def sales_order_line_mod(line)
          <<-XML

    <SalesOrderLineMod>
      <TxnLineID>#{line['txn_line_id']}</TxnLineID>
      #{sales_order_line(line)}
    </SalesOrderLineMod>
          XML
        end

        def sales_order_line_adjustment_mod(adjustment, params)
          line = {
            'product_id' => QBWC::Request::Adjustments.adjustment_product_from_qb(adjustment['name'], params),
            'quantity' => 0,
            'price' => adjustment['value'],
            'txn_line_id' => adjustment['txn_line_id']
          }

          sales_order_line_mod line
        end

        def sales_order_line(line)
          <<-XML

      <ItemRef>
        <FullName>#{line['product_id']}</FullName>
      </ItemRef>
      #{quantity(line)}
      <!-- <Amount>#{'%.2f' % line['price'].to_f}</Amount> -->
      <Rate>#{line['price']}</Rate>
      #{tax_code_line(line)}
          XML
        end

        def quantity(line)
          return '' if line['quantity'].to_f == 0.0

          "<Quantity>#{line['quantity']}</Quantity>"
        end

        def tax_code_line(line)
          return '' if line['tax_code_id'].to_s.empty?

          <<-XML

      <SalesTaxCodeRef>
        <FullName>#{line['tax_code_id']}</FullName>
      </SalesTaxCodeRef>
          XML
        end

        def cancel_order?(object)
          return '' unless object['status'].to_s == 'cancelled'

          <<-XML

          <IsManuallyClosed>true</IsManuallyClosed>

          XML
        end

        def build_customer_from_order(object)
          billing_address = object['billing_address']

          {
            'id'               => object['email'],
            'firstname'        => billing_address['firstname'],
            'lastname'         => billing_address['lastname'],
            'email'            => object['email'],
            'billing_address'  => billing_address,
            'shipping_address' => object['shipping_address']
          }
        end

        def build_products_from_order(object)
          object.first['line_items'].reject { |line| line['quantity'].to_f == 0.0 }.map do |item|
            {
              'id'          => item['product_id'],
              'description' => item['description'],
              'price'       => item['price'],
              'cost_price'  => item['price']
            }
          end
        end

        def build_payments_from_order(object)
          object['payments'].to_a.select { |pay| %w(completed paid ready).include?(pay['status']) && pay['amount'].to_f > 0.0 }.map do |item|
            item.merge('id'          => object['id'],
                       'object_ref'  => object['id'],
                       'email'       => object['email'])
          end
        end

        private

        def items(record)
          record['line_items'].to_a.sort { |a, b| a['product_id'] <=> b['product_id'] }
        end

        def adjustments(record)
          record['adjustments'].to_a.reject { |adj| adj['value'].to_f == 0.0 }.sort { |a, b| a['name'].downcase <=> b['name'].downcase }
        end

        def sanitize_order(order)
          order['billing_address']['address1'].gsub!(/[^0-9A-Za-z\s]/, '')
          order['billing_address']['address2'].gsub!(/[^0-9A-Za-z\s]/, '')
          order['billing_address']['city'].gsub!(/[^0-9A-Za-z\s]/, '')
          order['billing_address']['state'].gsub!(/[^0-9A-Za-z\s]/, '')
          order['billing_address']['zipcode'].gsub!(/[^0-9A-Za-z\s]/, '')
          order['billing_address']['country'].gsub!(/[^0-9A-Za-z\s]/, '')
          order['shipping_address']['address1'].gsub!(/[^0-9A-Za-z\s]/, '')
          order['shipping_address']['address2'].gsub!(/[^0-9A-Za-z\s]/, '')
          order['shipping_address']['city'].gsub!(/[^0-9A-Za-z\s]/, '')
          order['shipping_address']['state'].gsub!(/[^0-9A-Za-z\s]/, '')
          order['shipping_address']['zipcode'].gsub!(/[^0-9A-Za-z\s]/, '')
          order['shipping_address']['country'].gsub!(/[^0-9A-Za-z\s]/, '')
        end
      end
    end
  end
end
