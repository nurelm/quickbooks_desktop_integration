module Persistence
  class Object
    attr_reader :config, :objects, :payload_key, :amazon_s3, :path

    class << self
      def handle_error(config, error_context, object_type, request_id)
        Persistence::Object.new(config, {})
          .create_error_notifications(error_context, object_type, request_id)
      end

      def update_statuses(config = {}, processed = [], failed = [])
        Persistence::Object.new(config, {})
          .update_objects_files({ processed: processed, failed: failed }.with_indifferent_access)
      end
    end

    # +payload+ might have a collection of records when writing to s3
    #
    #   e.g. { orders: [{ id: "123" }, { id: "123" }] }
    #
    # or just the key when reading from s3
    #
    #   e.g. { orders: {} }
    #
    # or dont pass any payload if you want to get all data from a specific
    # account.
    #
    # +config+ should tell the :origin and the :connection_id
    #
    #   e.g. { origin: 'quickbooks', connection_id: '54372cb069702d1f59000000' }
    #
    def initialize(config = {}, payload = {})
      @payload_key = payload.keys.first
      @objects     = payload[payload_key].is_a?(Hash) ? [payload[payload_key]] : Array(payload[payload_key])
      @config      = { origin: 'wombat' }.merge(config).with_indifferent_access
      @amazon_s3   = S3Util.new
      @path        = Persistence::Path.new(@config)
    end

    # Doesn't check whether the record (s) is already in s3. Only save it.
    #
    # AmazonS3 will append a number to the end of the file.
    # e.g. orders_123123(1)
    # if it already exists.
    #
    # Files MUST be named like this
    # /connectionid/folder/objecttype_object_ref.csv
    #
    # e.g. 54372cb069702d1f59000000/wombat_pending/orders_T-SHIRT-SPREE1.csv
    # e.g. 54372cb069702d1f59000000/quickbooks_pending/orders_T-SHIRT-SPREE1.csv
    #
    def save
      objects.each do |object|
        next unless valid_object?(object)
        prepare_objects_before_save(object)

        if two_phase?
          file = "#{path.base_name}/#{path.two_phase_pending}/#{payload_key.pluralize}_#{id_of_object(object)}_.csv"
          amazon_s3.export file_name: file, objects: [object]
          generate_inserts_for_two_phase(object)
        else
          file = "#{path.base_name}/#{path.pending}/#{payload_key.pluralize}_#{id_of_object(object)}_.csv"
          amazon_s3.export file_name: file, objects: [object]
        end
        generate_extra_objects(object)
      end
    end

    # Get object files to query and get ListID and EditSequence
    #
    #   - Fetch files from s3
    #   - Move them to ready folder
    #   - Give it back as a Hash to be created a request
    #   - On Quickbooks callback request response we rename
    #    with ListID and EditSequence
    def process_pending_objects
      prefix = "#{path.base_name}/#{path.pending}"
      collection = amazon_s3.bucket.objects.with_prefix(prefix).enum

      collection.map do |s3_object|
        _, _, filename    = s3_object.key.split('/')
        object_type, _, _ = filename.split('_')

        contents = s3_object.read

        s3_object.move_to("#{path.base_name}/#{path.ready}/#{filename}")

        # return the content of file to create the requests
        { object_type => Converter.csv_to_hash(contents) }
      end.flatten
    end

    # Moves from two_phase_pending to pending, than will
    # be executed the next time
    def process_two_phase_pending_objects
      prefix = "#{path.base_name}/#{path.two_phase_pending}"
      collection = amazon_s3.bucket.objects

      collection.with_prefix(prefix).enum.each do |s3_object|
        _, _, filename    = s3_object.key.split('/')
        object_type, _, _ = filename.split('_')

        contents = s3_object.read

        s3_object.move_to("#{path.base_name}/#{path.pending}/#{filename}")
      end
    end

    # Rename files with ListID and EditSequence in ready folder
    # objects_to_be_renamed = [ { :object_type => 'product'
    #                             :object_ref => 'T-SHIRT-SPREE-1',
    #                             :list_id => '800000-88888',
    #                             :edit_sequence => '12312312321'}
    #                             :extra_data => { ... }, ]
    def update_objects_with_query_results(objects_to_be_renamed)
      prefix = "#{path.base_name}/#{path.ready}"

      unless amazon_s3.bucket.objects.with_prefix(prefix).first
        puts " No Files to be updated at #{prefix}"
        return
      end

      objects_to_be_renamed.to_a.compact.each do |object|
        filename     = "#{prefix}/#{object[:object_type].pluralize}_#{object[:object_ref]}_"

        # TODO what if the file is not there? we should probably at least
        # rescue / log the exception properly and move on with the others?
        # raises when file is not found:
        #
        #   AWS::S3::Errors::NoSuchKey - No Such Key:
        #
        begin
          s3_object     = amazon_s3.bucket.objects["#{filename}.csv"]
          new_file_name = "#{filename}#{object[:list_id]}_#{object[:edit_sequence]}.csv"
          s3_object.move_to(new_file_name)

          unless object[:extra_data].to_s.empty?
            contents = amazon_s3.bucket.objects[new_file_name].read
            amazon_s3.bucket.objects[new_file_name].delete

            with_extra_data = Converter.csv_to_hash(contents).first.merge(object[:extra_data])
            amazon_s3.export file_name: new_file_name, objects: [with_extra_data]
          end
        rescue AWS::S3::Errors::NoSuchKey => e
          puts " File not found: #{filename}.csv"
        end
      end
    end

    # Get objects from ready folder to insert/update on quickbooks
    # return type sample:
    # [ { 'products' =>  {
    #       :list_id => '111',
    #       :edit_sequence => '22222',
    #       ....
    #      },
    #     'orders' => {
    #       :list_id => '111',
    #       :edit_sequence => '22222',
    #       ....
    #     }
    #   }]
    def get_ready_objects_to_send
      prefix = "#{path.base_name}/#{path.ready}"
      collection = amazon_s3.bucket.objects.with_prefix(prefix).enum

      select_precedence_files(collection).reject { |s3| s3.key.match(/notification/) }.map do |s3_object|
        _, _, filename                         = s3_object.key.split('/')
        object_type, _, list_id, edit_sequence = filename.split('_')

        list_id.gsub!('.csv', '') unless list_id.nil?
        edit_sequence.gsub!('.csv', '') unless edit_sequence.nil?
        list_id = nil if edit_sequence.nil? # To fix a problem with multiple files with (n) on it

        contents = s3_object.read

        { object_type.pluralize =>
            { list_id: list_id, edit_sequence: edit_sequence }
              .merge(Converter.csv_to_hash(contents).first).with_indifferent_access
        }
      end.flatten
    end

    # Move files from `ready` folder to `processed` or `failed` accordingly
    # statuses_objects look like this:
    # { :processed => [
    #     { 'products' =>  {
    #         :list_id => '111',
    #         :edit_sequence => '22222',
    #         ....
    #        },
    #       'orders' => {
    #         :list_id => '111',
    #         :edit_sequence => '22222',
    #         ....
    #       }
    #     }
    #   ],
    #   :failed => [] }
    def update_objects_files(statuses_objects)
      return if statuses_objects.nil?

      statuses_objects.keys.each do |status_key|
        statuses_objects[status_key].each do |types|
          types.keys.each do |object_type|
            # NOTE seeing an nil `object` var here sometimes, investigate it
            # happens when you have both add_orders and get_products flows enabled
            begin
              object = types[object_type].with_indifferent_access

              filename = "#{path.base_name}/#{path.ready}/#{object_type}_#{id_for_object(object, object_type)}_"

              collection = amazon_s3.bucket.objects
              collection.with_prefix(filename).enum.each do |s3_object|
                # This is for files that end on (n)
                _, _, ax_filename = s3_object.key.split('/')
                _, _, end_of_file, ax_edit_sequence = ax_filename.split('_')
                end_of_file = '.csv' unless ax_edit_sequence.nil?

                status_folder = path.send status_key
                new_filename = "#{path.base_name}/#{status_folder}/#{object_type}_#{id_for_object(object, object_type)}_"
                new_filename << "#{object[:list_id]}_#{object[:edit_sequence]}" unless object[:list_id].to_s.empty?

                s3_object.move_to("#{new_filename}#{end_of_file}")

                create_notifications("#{new_filename}#{end_of_file}", status_key) if status_key == 'processed'
              end
            rescue Exception => e
              puts " update_objects_files: #{statuses_objects} #{e.backtrace.inspect}"
            end
          end
        end
      end
    end

    def get_notifications
      prefix = "#{path.base_name}/#{path.ready}/notification_"
      collection = amazon_s3.bucket.objects.with_prefix(prefix).enum

      notification_files = collection.select do |s3|
        s3.key.match(payload_key) || (payload_key == 'orders' && s3.key.match('payments'))
      end

      notification_files.inject('processed' => {}, 'failed' => {}) do |notifications, s3_object|
        _, _, filename  = s3_object.key.split('/')
        _, status, object_type, object_ref, _ = filename.split('_')
        content = amazon_s3.convert_download('csv', s3_object.read).first

        object_ref = id_for_notifications(content, object_ref)

        if content.key?('message')
          notifications[status][content['message']] ||= []
          notifications[status][content['message']] << object_ref
        else
          notifications[status][success_notification_message(object_type)] ||= []
          notifications[status][success_notification_message(object_type)] << object_ref
        end

        s3_object.move_to("#{path.base_name}/#{path.processed}/#{filename}")

        notifications
      end
    end

    def create_error_notifications(error_context, object_type, request_id)
      # When there is an error in one request, QB invalidate all other requests, to avoid a lack of objects being processed
      # if the error was this, then the object stay there to process next time
      if error_context[:message] != 'The request has not been processed.'
        session = Persistence::Session.load(config, request_id)
        generate_error_notification(error_context.merge(object: session), object_type)
        update_objects_files({ processed: [], failed: [{ object_type => session }] }.with_indifferent_access)
      end
    end

    # This link invoices and payments
    def update_shipments_with_payment_ids(shipment_id, object)
      file_name = "#{path.base_name}/#{path.pending}/shipments_#{shipment_id}_.csv"

      begin
        contents = amazon_s3.convert_download('csv', amazon_s3.bucket.objects[file_name].read)
        amazon_s3.bucket.objects[file_name].delete
      rescue AWS::S3::Errors::NoSuchKey => _e
        puts "File not found[update_shipments_with_payment_ids]: #{file_name}"
      end

      contents.first['payment'] = object

      amazon_s3.export file_name: file_name, objects: contents

      begin
        order_file_name = "#{path.base_name}/#{path.ready}/payments_#{object[:object_ref]}_.csv"
        amazon_s3.bucket.objects[order_file_name].delete
      rescue AWS::S3::Errors::NoSuchKey => _e
        puts "File not found[delete payments]: #{file_name}"
      end
    end

    # This link Invoices with Sales Orders
    def update_shipments_with_qb_ids(shipment_id, object)
      file_name = "#{path.base_name}/#{path.pending}/shipments_#{shipment_id}_.csv"

      begin
        contents = amazon_s3.convert_download('csv', amazon_s3.bucket.objects[file_name].read)
        amazon_s3.bucket.objects[file_name].delete
      rescue AWS::S3::Errors::NoSuchKey => _e
        puts "File not found[update_shipments_with_qb_ids]: #{file_name}"
      end

      contents.first['items'] = object[:extra_data]['line_items']
                                .map do |item|
        item['sales_order_txn_line_id'] = item['txn_line_id']
        item['sales_order_txn_id']      = item['txn_id']
        item.delete('txn_line_id')
        item.delete('txn_id')
        item
      end

      contents.first['adjustments'] = object[:extra_data]['adjustments']
                                      .map do |item|
        item['sales_order_txn_line_id'] = item['txn_line_id']
        item['sales_order_txn_id']      = item['txn_id']
        item.delete('txn_line_id')
        item.delete('txn_id')
        item
      end

      amazon_s3.export file_name: file_name, objects: contents

      begin
        order_file_name = "#{path.base_name}/#{path.ready}/orders_#{object[:object_ref]}_.csv"
        amazon_s3.bucket.objects[order_file_name].delete
      rescue AWS::S3::Errors::NoSuchKey => _e
        puts "File not found[delete orders]: #{file_name}"
      end
    end

    # Creates payments to updates Invoices IDs into Payments and link one to another,
    # needs to be separated, because we need QB IDs and it's only exists after processed
    def create_payments_updates_from_shipments(_config, shipment_id, invoice_txn_id)
      file_name = "#{path.base_name}/#{path.ready}/shipments_#{shipment_id}_"

      begin
        file = amazon_s3.bucket.objects.with_prefix(file_name).enum.first

        contents = amazon_s3.convert_download('csv', file.read)
      rescue AWS::S3::Errors::NoSuchKey => _e
        puts "File not found[create_payments_updates_from_shipments]: #{file_name}"
      end
      object = contents.first

      save_object = [{
        'id'              => object['order_id'],
        'invoice_txn_id' => invoice_txn_id,
        'amount'         => object['totals']['payment'],
        'object_ref'     => object['order_id'],
        'list_id'        => object['payment']['list_id'],
        'edit_sequence'  => object['payment']['edit_sequence']
      }]

      new_file_name = "#{path.base_name}/#{path.ready}/payments_#{object['order_id']}_.csv"
      amazon_s3.export file_name: new_file_name, objects: save_object
    end

    private

    def select_precedence_files(collection)
      first_precedence_types = %w(customers products adjustments inventories payments)
      second_precedence_types = %w(orders returns)

      has_first_precedence_files = collection.select do |file|
        _, _, filename    = file.key.split('/')
        object_type, _, _ = filename.split('_')
        first_precedence_types.include?(object_type)
      end.any?

      has_second_precedence_files = collection.select do |file|
        _, _, filename    = file.key.split('/')
        object_type, _, _ = filename.split('_')
        second_precedence_types.include?(object_type)
      end.any?

      if has_first_precedence_files
        objects_to_process = collection.select do |file|
          _, _, filename    = file.key.split('/')
          object_type, _, _ = filename.split('_')
          first_precedence_types.include?(object_type)
        end
      elsif has_second_precedence_files
        objects_to_process = collection.select do |file|
          _, _, filename    = file.key.split('/')
          object_type, _, _ = filename.split('_')
          second_precedence_types.include?(object_type)
        end
      else
        objects_to_process = collection
      end
      objects_to_process
    end

    def success_notification_message(object)
      "#{object.singularize.capitalize} successfully sent to Quickbooks Desktop"
    end

    def generate_error_notification(content, object_type)
      @payload_key = object_type
      if content[:object]
        new_filename = "#{path.base_name}/#{path.ready}/notification_failed_#{object_type}_#{id_for_object(content[:object], object_type)}_.csv"
        amazon_s3.export(file_name: new_filename, objects: [content])
      else
        puts "generate_error_notification: #{content.inspect}:#{object_type}"
      end
    end

    def create_notifications(objects_filename, status)
      _, _, filename = objects_filename.split('/')
      s3_object = amazon_s3.bucket.objects[objects_filename]

      new_filename = "#{path.base_name}/#{path.ready}/notification_#{status}_#{filename}"
      s3_object.copy_to(new_filename)
    end

    def valid_object?(object)
      if payload_key.pluralize == 'orders'
        if object['id'].size > 11
          generate_error_notification({ context: 'Saving orders',
                                        code: '',
                                        message: 'Could not import to qb the Order ID exceeded the limit of 11',
                                        object: object }, payload_key.pluralize)
          return false
        end
      elsif payload_key.pluralize == 'returns'
        if object['id'].size > 11
          generate_error_notification({ context: 'Saving returns',
                                        code: '',
                                        message: 'Could not import to qb the RMA ID exceeded the limit of 11',
                                        object: object }, payload_key.pluralize)
          return false
        end
      end
      true
    end

    def prepare_objects_before_save(object)
      object['status'] = 'cancelled' if config['flow'] == 'cancel_order'
    end

    # When inventory is updated, QB doesn't update item inventory,
    # this is to force this update and
    # return to Wombat item inventories updated
    def generate_extra_objects(object)
      if payload_key.pluralize == 'inventories'
        object_aux = object.dup
        object_aux['id'] = object_aux['product_id']
        object_aux['active'] = true

        save_pending_file(object_aux['id'], 'products', object_aux)
      end
    end

    def generate_inserts_for_two_phase(object)
      # TODO Create a better way to choose between types
      if payload_key.pluralize == 'orders'
        customer = QBWC::Request::Orders.build_customer_from_order(object)
        products = QBWC::Request::Orders.build_products_from_order(objects)
        payments = QBWC::Request::Orders.build_payments_from_order(object)

        save_pending_file(customer['id'], 'customers', customer)

        products.flatten.each do |product|
          save_pending_file(product['id'], 'products', product)
        end

        payments.flatten.each do |payment|
          save_pending_file(payment['id'], 'payments', payment)
        end
      elsif payload_key.pluralize == 'shipments'
        customer = QBWC::Request::Shipments.build_customer_from_shipments(object)
        products = QBWC::Request::Shipments.build_products_from_shipments(objects)
        order    = QBWC::Request::Shipments.build_order_from_shipments(object)
        payment  = QBWC::Request::Shipments.build_payment_from_shipments(object)

        save_pending_file(customer['id'], 'customers', customer)
        save_pending_file(order['id'], 'orders', order)
        save_pending_file(payment['id'], 'payments', order)
        products.each do |product|
          save_pending_file(product['id'], 'products', product)
        end
      end
    end

    def save_pending_file(object_ref, object_type, object)
      amazon_s3.export file_name: "#{path.base_name}/#{path.pending}/#{object_type}_#{object_ref}_.csv", objects: [object]
    end

    def two_phase?
      %w(orders shipments).include?(payload_key.pluralize)
    end

    def id_of_object(object)
      id_for_object(object, payload_key.pluralize)
    end

    # deprecated
    def id_for_notifications(object, object_ref)
      id = id_for_object(object, payload_key.pluralize)
      return id if id != object['id']

      object_ref
    end

    def id_for_object(object, object_type)
      key = object_type.pluralize

      if key == 'customers'
        object['email']
      elsif key == 'shipments'
        object['order_id']
      else
        object['id']
      end
    end
  end
end
