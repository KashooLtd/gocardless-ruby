require 'date'

module GoCardless
  class Resource
    def initialize(client, hash = {})
      @client = client

      # Handle sub resources
      sub_resource_uris = hash.delete('sub_resource_uris')
      unless sub_resource_uris.nil?
        # Need to define a method for each sub resource
        sub_resource_uris.each do |name,uri|
          uri = URI.parse(uri)

          # Convert the query string to a hash
          query = if uri.query.nil? || uri.query == ''
            nil
          else
            Hash[CGI.parse(uri.query).map { |k,v| [k,v.first] }]
          end

          # Strip api prefix from path
          path = uri.path.sub(%r{^/api/v\d+}, '')

          # Modify the instance's metaclass to add the method
          metaclass = class << self; self; end
          metaclass.send(:define_method, name) do
            # 'name' will be something like 'bills', convert it to Bill and
            # look up the resource class with that name
            klass = GoCardless.const_get(name.to_s.singularize.camelize)
            # Convert the results to instances of the looked-up class
            client.api_get(path, query).map do |attrs|
              klass.new(client, attrs)
            end
          end
        end
      end

      # Set resource attribute values
      hash.each { |key,val| send("#{key}=", val) }
    end

    class << self
      attr_accessor :endpoint

      def find(client, id)
        path = endpoint.gsub(':id', id.to_s)
        data = client.api_get(path)
        self.new(client, data)
      end

      def date_writer(*args)
        args.each do |attr|
          define_method("#{attr.to_s}=".to_sym) do |date|
            date = date.is_a?(String) ? DateTime.parse(date) : date
            instance_variable_set("@#{attr}", date)
          end
        end
      end

      def date_accessor(*args)
        attr_reader *args
        date_writer *args
      end

      def reference_reader(*args)
        attr_reader *args

        args.each do |attr|
          if !attr.to_s.end_with?('_id')
            raise ArgumentError, 'reference_reader args must end with _id'
          end

          name = attr.to_s.sub(/_id$/, '')
          define_method(name.to_sym) do
            obj_id = instance_variable_get("@#{attr}")
            klass = GoCardless.const_get(name.camelize)
            klass.find(@client, obj_id)
          end
        end
      end

      def reference_writer(*args)
        attr_writer *args

        args.each do |attr|
          if !attr.to_s.end_with?('_id')
            raise ArgumentError, 'reference_writer args must end with _id'
          end

          name = attr.to_s.sub(/_id$/, '')
          define_method("#{name}=".to_sym) do |obj|
            klass = GoCardless.const_get(name.camelize)
            if !obj.is_a?(klass)
              raise ArgumentError, "Object must be an instance of #{klass}"
            end

            instance_variable_set("@#{attr}", obj.id)
          end
        end
      end

      def reference_accessor(*args)
        reference_reader *args
        reference_writer *args
      end

      def creatable(val = true)
        @creatable = val
      end

      def updatable(val = true)
        @updatable = val
      end

      def creatable?
        !!@creatable
      end

      def updatable?
        !!@updatable
      end
    end


    # @macro [attach] resource.property
    # @return [String] the $1 property of the object
    attr_accessor :id
    attr_accessor :uri

    def to_hash
      attrs = instance_variables.map { |v| v.to_s.sub(/^@/, '') }
      Hash[attrs.select { |v| respond_to? v }.map { |v| [v.to_sym, send(v)] }]
    end

    def to_json
      to_hash.to_json
    end

    def inspect
      "#<#{self.class} #{to_hash.map { |k,v| "#{k}=#{v.inspect}" }.join(', ')}>"
    end

    def persisted?
      !id.nil?
    end

    # Save a resource on the API server. If the resource already exists (has a
    # non-null id), it will be updated with a PUT, otherwise it will be created
    # with a POST.
    def save
      save_data self.to_hash
      self
    end

  protected

    def save_data(data)
      method = if self.persisted?
        raise "#{self.class} cannot be updated" unless self.class.updatable?
        'put'
      else
        raise "#{self.class} cannot be created" unless self.class.creatable?
        'post'
      end
      path = self.class.endpoint.gsub(':id', id.to_s)
      response = @client.send("api_#{method}", path, data)
      response.each { |key,val| send("#{key}=", val) } if response.is_a? Hash
    end
  end
end