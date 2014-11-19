module QBWC
  module Response
    class CustomerAddRs
      attr_reader :records

      def initialize(records)
        @records = records
      end

      def handle_error(errors, config)

      end

      def process(config = {})
        return { statuses_objects: nil }.with_indifferent_access if records.empty?


        # TODO Error handling

        # &lt;QBXML&gt;
        # &lt;QBXMLMsgsRs&gt;
        # &lt;ItemInventoryAddRs statusCode="3100" statusSeverity="Error" statusMessage="The name &amp;quot;SPREE-T-SHIRT697877&amp;quot; of the list element is already in use." /&gt;
        # &lt;/QBXMLMsgsRs&gt;
        # &lt;/QBXML&gt;
        # </response><hresult /><message /></receiveResponseXML></soap:Body></soap:Envelope>

        puts " \n\n\n **** Records: #{records.inspect} \n\n"

        objects = records.map do |object|
          { customers: {
            id: object['Name'],
            list_id: object['ListID'],
            edit_sequence: object['EditSequence'] } }
        end

        config  = { origin: 'wombat', connection_id: config[:connection_id]  }
        Persistence::Object.new(config, {}).update_objects_files({ processed: objects, failed: [] }.with_indifferent_access)
      end
    end
  end
end
