module QBWC
  module Request
    class Orders
      class << self
        def config
          {
            'quickbooks_income_account'    => 'Inventory Asset',
            'quickbooks_cogs_account'      => 'Inventory Asset',
            'quickbooks_inventory_account' => 'Inventory Asset'
          }
        end

        # We can only query by txn_id or ref_number, check sales_order_query_rq.xml
        def generate_request_queries(objects, params)
          objects.inject("") do |request, object|
            if txn_id = object['quickbooks_txn_id']
              request << search_xml(txn_id)
            else
              request
            end
          end
        end

        def generate_request_insert_update(objects, params = {})
          objects.inject("") do |request, object|
            if object['quickbooks_txn_id'].to_s.empty?
              # TODO Test me. Didnt have a chance yet =/ working offline (airport wifi)
              request << Customers.add_xml_to_send(build_customer(object)) +
                build_items_refs_xml(object) +
                sales_order_add_rq(object, config.merge(params))
            else
              # work on update xml request
              request << ''
            end
          end
        end

        # TODO Should probably stick with customer_id key instead of
        # depending on firstname / lastname? going with default wombat
        # format for now ..
        def customer_ref(record)
          billing = record['billing_address']
          "#{billing['firstname']} #{billing['lastname']}"
        end

        def build_customer(object)
          billing_address = object['billing_address']

          {
            'id' => "#{billing_address['firstname']} #{billing_address['lastname']}",
            'firstname' => billing_address['firstname'],
            'lastname' => billing_address['lastname'],
            'email' => object['email'],
            'billing_address' => billing_address,
            'shipping_address' => object['shipping_address']
          }
        end

        def customer_ref_query(record)
          <<-XML
            <CustomerQueryRq>
              <FullName>#{customer_ref record}</FullName>
            </CustomerQueryRq>
          XML
        end

        def build_items_refs_xml(record)
          record['line_items'].inject('') do |xml, item|
            object = {
              'id' => item['product_id'],
              'description' => item['description'],
              'price' => item['price']
            }

            xml << Products.add_xml_to_send(record, config)
          end
        end

        def search_xml(txn_id)
         <<-XML
          <SalesOrderQueryRq>
            <TxnID>#{txn_id}</TxnID>
            <!-- <RefNumberCaseSensitive>STRTYPE</RefNumberCaseSensitive> -->
          </SalesOrderQueryRq>
          XML
        end

        def sales_order_add_rq(record, params= {})
          <<-XML
            <SalesOrderAddRq>
              <SalesOrderAdd>
                #{sales_order record, params}
              </SalesOrderAdd>
            </SalesOrderAddRq>
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
        # R154085346875 is a too long value for RefNumber so lets use
        # PONumber to map Wombat orders id instead. Quickbooks
        # will increment RefNumber each time a sales order is created
        #
        # 'placed_on' needs to be a valid date string otherwise an exception
        # will be raised
        #
        def sales_order(record, params)
          <<-XML
            <CustomerRef>
              <FullName>#{customer_ref record}</FullName>
            </CustomerRef>
            <TxnDate>#{Time.parse(record['placed_on']).to_date}</TxnDate>
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
            <PONumber>#{record['id']}</PONumber>
            #{record['line_items'].map { |l| sales_order_line l }.join("")}
          XML
        end

        def sales_order_line(line)
          <<-XML
            <SalesOrderLineAdd>
              <ItemRef>
                <FullName>#{line['product_id']}</FullName>
              </ItemRef>
              <Quantity>#{line['quantity']}</Quantity>
              <!-- <Amount>#{'%.2f' % line['price'].to_f}</Amount> -->
              <Rate>#{line['price']}</Rate>
              <!-- might be needed same as tax_code_id in qb online -->
              <!-- <SalesTaxCodeRef> -->
              <!--   <ListID>IDTYPE</ListID> -->
              <!--   <FullName>STRTYPE</FullName> -->
              <!-- </SalesTaxCodeRef> -->
            </SalesOrderLineAdd>
          XML
        end
      end
    end
  end
end
