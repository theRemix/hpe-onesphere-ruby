require_relative 'client'

module OneSphere
  # Resource base class that defines all common resource functionality.
  class Resource
    BASE_URI = '/rest'.freeze
    UNIQUE_IDENTIFIERS = %w[name uri].freeze # Ordered list of unique attributes to search by
    DEFAULT_REQUEST_HEADER = {}.freeze

    attr_accessor \
      :client,
      :data,
      :logger

    # Create a resource object, associate it with a client, and set its properties.
    # @param [Onevsphere::Client] client The client object for OneSphere
    # @param [Hash] params The options for this resource (key-value pairs)
    def initialize(client, params = {})
      raise InvalidClient, 'Must specify a valid client'\
        unless client.is_a?(OneSphere::Client)
      @client = client
      @logger = @client.logger
      @data ||= {}
      set_all(params)
    end

    # Retrieve resource details based on this resource's name or URI.
    # @note one of the UNIQUE_IDENTIFIERS, e.g. name or uri, must be specified in the resource
    # @param [Hash] header The header options for the request (key-value pairs)
    # @return [Boolean] Whether or not retrieve was successful
    def retrieve!(header = self.class::DEFAULT_REQUEST_HEADER)
      retrieval_keys = self.class::UNIQUE_IDENTIFIERS.reject { |k| @data[k].nil? }
      raise IncompleteResource, "Must set resource #{self.class::UNIQUE_IDENTIFIERS.join(' or ')} before trying to retrieve!" if retrieval_keys.empty?
      retrieval_keys.each do |k|
        results = self.class.find_by(@client, { k => @data[k] }, self.class::BASE_URI, header)
        next if results.size != 1
        set_all(results[0].data)
        return true
      end
      false
    end

    # Check if a resource exists
    # @note one of the UNIQUE_IDENTIFIERS, e.g. name or uri, must be specified in the resource
    # @param [Hash] header The header options for the request (key-value pairs)
    # @return [Boolean] Whether or not resource exists
    def exists?(header = self.class::DEFAULT_REQUEST_HEADER)
      retrieval_keys = self.class::UNIQUE_IDENTIFIERS.reject { |k| @data[k].nil? }
      raise IncompleteResource, "Must set resource #{self.class::UNIQUE_IDENTIFIERS.join(' or ')} before trying to retrieve!" if retrieval_keys.empty?
      retrieval_keys.each do |k|
        results = self.class.find_by(@client, { k => @data[k] }, self.class::BASE_URI, header)
        return true if results.size == 1
      end
      false
    end

    # Set the given hash of key-value pairs as resource data attributes
    # @param [Hash, Resource] params The options for this resource (key-value pairs or resource object)
    # @note All top-level keys will be converted to strings
    # @return [Resource] self
    def set_all(params = self.class::DEFAULT_REQUEST_HEADER)
      params = params.data if params.class <= Resource
      params = Hash[params.map { |(k, v)| [k.to_s, v] }]
      params.each { |key, value| set(key.to_s, value) }
      self
    end

    # Set a resource attribute with the given value and call any validation method if necessary
    # @param [String] key attribute name
    # @param value value to assign to the given attribute
    # @note Keys will be converted to strings
    def set(key, value)
      method_name = "validate_#{key}"
      send(method_name.to_sym, value) if respond_to?(method_name.to_sym)
      @data[key.to_s] = value
    end

    # Run block once for each data key-value pair
    def each(&block)
      @data.each(&block)
    end

    # Access data using hash syntax
    # @param [String, Symbol] key Name of key to get value for
    # @return The value of the given key. If not found, returns nil
    # @note The key will be converted to a string
    def [](key)
      @data[key.to_s]
    end

    # Set data using hash syntax
    # @param [String, Symbol] key Name of key to set the value for
    # @param [Object] value to set for the given key
    # @note The key will be converted to a string
    # @return The value set for the given key
    def []=(key, value)
      set(key, value)
    end

    # Check equality of 2 resources. Same as eql?(other)
    # @param [Resource] other The other resource to check equality for
    # @return [Boolean] Whether or not the two objects are equal
    def ==(other)
      self_state  = instance_variables.sort.map { |v| instance_variable_get(v) }
      other_state = other.instance_variables.sort.map { |v| other.instance_variable_get(v) }
      other.class == self.class && other_state == self_state
    end

    # Check equality of 2 resources. Same as ==(other)
    # @param [Resource] other The other resource to check for equality
    # @return [Boolean] Whether or not the two objects are equal
    def eql?(other)
      self == other
    end

    # Check the equality of the data for the other resource with this resource.
    # @param [Hash, Resource] other resource or hash to compare the key-value pairs with
    # @return [Boolean] Whether or not the two objects are alike
    def like?(other)
      recursive_like?(other, @data)
    end


    # Create the resource on OneSphere using the current data
    # @note Calls the refresh method to set additional data
    # @param [Hash] header The header options for the request (key-value pairs)
    # @return [Resource] self
    def create(header = self.class::DEFAULT_REQUEST_HEADER)
      ensure_client
      options = {}.merge(header).merge('body' => @data)
      response = @client.rest_post(self.class::BASE_URI, options)
      body = @client.response_handler(response)
      set_all(body)
      self
    end

    # Delete the resource from OneSphere if it exists, then create it using the current data
    # @note Calls refresh method to set additional data
    # @param [Hash] header The header options for the request (key-value pairs)
    # @return [Resource] self
    def create!(header = self.class::DEFAULT_REQUEST_HEADER)
      temp = self.class.new(@client, @data)
      temp.delete(header) if temp.retrieve!(header)
      create(header)
    end

    # Updates this object using the data that exists on OneSphere
    # @param [Hash] header The header options for the request (key-value pairs)
    # @return [Resource] self
    def refresh(header = self.class::DEFAULT_REQUEST_HEADER)
      ensure_client && ensure_uri
      response = @client.rest_get(@data['uri'], header)
      body = @client.response_handler(response)
      set_all(body)
      self
    end

    # @param [Hash] attributes The attributes to add/change for this resource (key-value pairs)
    # @param [Hash] header The header options for the request (key-value pairs)
    # @return [Resource] self
    def update(attributes = {}, header = self.class::DEFAULT_REQUEST_HEADER)
      set_all(attributes)
      ensure_client && ensure_uri
      options = {}.merge(header).merge('body' => @data)
      response = @client.rest_patch(@data['uri'], options)
      @client.response_handler(response)
      self
    end

    # Delete resource from OneSphere
    # @param [Hash] header The header options for the request (key-value pairs)
    # @return [true] if resource was deleted successfully
    def delete(header = self.class::DEFAULT_REQUEST_HEADER)
      ensure_client && ensure_uri
      response = @client.rest_delete(@data['uri'], header)
      @client.response_handler(response)
      true
    end

    # Builds a Query string corresponding to the parameters passed
    # @param [Hash] attributes Hash containing the attributes name and value
    # @param [String] build_query of the endpoint
    def self.build_query(query_options)
      return '' if !query_options || query_options.empty?
      query_path = '?'
      query_options.each do |k, v|
        v = "'" + v.join(',') + "'" if v.is_a?(Array) && v.any?
        query_path.concat("&#{k}=#{v}")
      end
      query_path.sub('?&', '?')
    end

    # Make a GET request to the resource uri, and returns an array with results matching the search
    # @param [Hash] attributes Hash containing the attributes name and value
    # @param [String] uri URI of the endpoint
    # @param [Hash] header The header options for the request (key-value pairs)
    # @return [Array<Resource>] Results matching the search
    def self.find_by(client, attributes, uri = self::BASE_URI, header = self::DEFAULT_REQUEST_HEADER)
      uri = self::BASE_URI + self.build_query(attributes)
      all = find_with_pagination(client, uri, header)
      all
    end

    # Make a GET request to the uri, and returns an array with all results (search using resource pagination)
    # @param [OneSphere::Client] client The client object for OneSphere
    # @param [String] uri URI of the endpoint
    # @param [Hash] header The header options for the request (key-value pairs)
    # @return [Array<Hash>] Results
    def self.find_with_pagination(client, uri, header = self::DEFAULT_REQUEST_HEADER)
      all = []
      loop do
        response = client.rest_get(uri, header)
        body = client.response_handler(response)
        members = body['members']
        break unless members
        all.concat(members)
        break unless body['nextPageUri'] && (body['nextPageUri'] != body['uri'])
        uri = body['nextPageUri']
      end
      all
    end

    # Make a GET request to the resource base uri, and returns an array with all objects of this type
    # @param [OneSphere::Client] client The client object for OneSphere
    # @param [Hash] header The header options for the request (key-value pairs)
    # @return [Array<Resource>] Results
    def self.get_all(client, header = self::DEFAULT_REQUEST_HEADER)
      find_by(client, {}, self::BASE_URI, header)
    end

    protected

    # Fail unless @client is set for this resource.
    def ensure_client
      raise IncompleteResource, 'Please set client attribute before interacting with this resource' unless @client
      true
    end

    # Fail unless @data['uri'] is set for this resource.
    def ensure_uri
      raise IncompleteResource, 'Please set uri attribute before interacting with this resource' unless @data['uri']
      true
    end

    # Fail for methods that are not available for one resource
    def unavailable_method
      raise MethodUnavailable, "The method ##{caller(1..1).first[/`.*'/][1..-2]} is unavailable for this resource"
    end

    # Recursive helper method for like?
    # Allows comparison of nested hash structures
    def recursive_like?(other, data = @data)
      raise "Can't compare with object type: #{other.class}! Must respond_to :each" unless other.respond_to?(:each)
      other.each do |key, val|
        return false unless data && data.respond_to?(:[])
        if val.is_a?(Hash)
          return false unless data.class == Hash && recursive_like?(val, data[key.to_s])
        elsif val.is_a?(Array) && val.first.is_a?(Hash)
          data_array = data[key.to_s] || data[key.to_sym]
          return false unless data_array.is_a?(Array)
          val.each do |other_item|
            return false unless data_array.find { |data_item| recursive_like?(other_item, data_item) }
          end
        elsif val.to_s != data[key.to_s].to_s && val.to_s != data[key.to_sym].to_s
          return false
        end
      end
      true
    end

  end
end