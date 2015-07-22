# Copyright 2014 Google Inc. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

module Fluent
  # fluentd output plugin for the Google Cloud Logging API
  class GoogleCloudOutput < BufferedOutput
    Fluent::Plugin.register_output('google_cloud', self)

    # Constants for service names.
    APPENGINE_SERVICE = 'appengine.googleapis.com'
    COMPUTE_SERVICE = 'compute.googleapis.com'
    DATAFLOW_SERVICE = 'dataflow.googleapis.com'
    EC2_SERVICE = 'ec2.amazonaws.com'

    # Name of the the Google cloud logging write scope.
    LOGGING_SCOPE = 'https://www.googleapis.com/auth/logging.write'

    # Address of the metadata service.
    METADATA_SERVICE_ADDR = '169.254.169.254'

    # Disable this warning to conform to fluentd config_param conventions.
    # rubocop:disable Style/HashSyntax

    # DEPRECATED: auth_method (and support for 'private_key') is deprecated in
    # favor of Google Application Default Credentials as documented at:
    # https://developers.google.com/identity/protocols/application-default-credentials
    # 'private_key' is still accepted to support existing users; any other
    # value is ignored.
    config_param :auth_method, :string, :default => nil

    # DEPRECATED: Parameters necessary to use the private_key auth_method.
    config_param :private_key_email, :string, :default => nil
    config_param :private_key_path, :string, :default => nil
    config_param :private_key_passphrase, :string, :default => 'notasecret'

    # Specify project/instance metadata.
    #
    # project_id, zone, and vm_id are required to have valid values, which
    # can be obtained from the metadata service or set explicitly.
    # Otherwise, the plugin will fail to initialize.
    #
    # Whether to attempt to obtain metadata from the local metadata service.
    # It is safe to specify 'true' even on platforms with no metadata service.
    config_param :use_metadata_service, :bool, :default => true
    # These parameters override any values obtained from the metadata service.
    config_param :project_id, :string, :default => nil
    config_param :zone, :string, :default => nil
    config_param :vm_id, :string, :default => nil

    # label_map (specified as a JSON object) is an unordered set of fluent
    # field names whose values are sent as labels rather than as part of the
    # struct payload.
    #
    # Each entry in the map is a {"field_name": "label_name"} pair.  When
    # the "field_name" (as parsed by the input plugin) is encountered, a label
    # with the corresponding "label_name" is added to the log entry.  The
    # value of the field is used as the value of the label.
    #
    # The map gives the user additional flexibility in specifying label
    # names, including the ability to use characters which would not be
    # legal as part of fluent field names.
    #
    # Example:
    #   label_map {
    #     "field_name_1": "sent_label_name_1",
    #     "field_name_2": "some.prefix/sent_label_name_2"
    #   }
    config_param :label_map, :hash, :default => nil

    # rubocop:enable Style/HashSyntax

    # TODO: Add a log_name config option rather than just using the tag?

    # Expose attr_readers to make testing of metadata more direct than only
    # testing it indirectly through metadata sent with logs.
    attr_reader :project_id
    attr_reader :zone
    attr_reader :vm_id
    attr_reader :running_on_managed_vm
    attr_reader :gae_backend_name
    attr_reader :gae_backend_version
    attr_reader :service_name
    attr_reader :common_labels

    def initialize
      super
      require 'cgi'
      require 'google/api_client'
      require 'google/api_client/auth/compute_service_account'
      require 'googleauth'
      require 'json'
      require 'open-uri'

      # use the global logger
      @log = $log # rubocop:disable Style/GlobalVars
    end

    def configure(conf)
      super

      unless @auth_method.nil?
        @log.warn 'auth_method is deprecated; please migrate to using ' \
          'Application Default Credentials.'
        if @auth_method == 'private_key'
          if !@private_key_email
            fail Fluent::ConfigError, '"private_key_email" must be ' \
              'specified if auth_method is "private_key"'
          elsif !@private_key_path
            fail Fluent::ConfigError, '"private_key_path" must be ' \
              'specified if auth_method is "private_key"'
          elsif !@private_key_passphrase
            fail Fluent::ConfigError, '"private_key_passphrase" must be ' \
              'specified if auth_method is "private_key"'
          end
        end
      end

      # TODO: Send instance tags and/or hostname as labels as well?
      @common_labels = {}

      # set attributes from metadata (unless overriden by static config)
      @platform = detect_platform
      case @platform
      when Platform::GCE
        if @project_id.nil?
          @project_id = fetch_gce_metadata('project/project-id')
        end
        if @zone.nil?
          # this returns "projects/<number>/zones/<zone>"; we only want
          # the part after the final slash.
          fully_qualified_zone = fetch_gce_metadata('instance/zone')
          @zone = fully_qualified_zone.rpartition('/')[2]
        end
        @vm_id = fetch_gce_metadata('instance/id') if @vm_id.nil?
      when Platform::EC2
        metadata = fetch_ec2_metadata
        if @zone.nil? && metadata.key?('availabilityZone')
          @zone = 'aws:' + metadata['availabilityZone']
        end
        if @vm_id.nil? && metadata.key?('instanceId')
          @vm_id = metadata['instanceId']
        end
        if metadata.key?('accountId')
          common_labels["#{EC2_SERVICE}/account_id"] = metadata['accountId']
        end
      when Platform::OTHER
        # do nothing
      else
        fail Fluent::ConfigError, 'Unknown platform ' + @platform
      end

      # all metadata parameters must now be set
      unless @project_id && @zone && @vm_id
        missing = []
        missing << 'project_id' unless @project_id
        missing << 'zone' unless @zone
        missing << 'vm_id' unless @vm_id
        fail Fluent::ConfigError, 'Unable to obtain metadata parameters: ' +
          missing.join(' ')
      end

      # Default this to false; it is only overwritten if we detect Managed VM.
      @running_on_managed_vm = false

      # Set labels, etc. based on the config
      case @platform
      when Platform::GCE
        @service_name = COMPUTE_SERVICE
        # Check for specialized GCE environments (Managed VM or Dataflow).
        # TODO: Add config options for these to allow for running outside GCE?
        attributes = fetch_gce_metadata('instance/attributes/').split
        if attributes.include?('gae_backend_name') &&
           attributes.include?('gae_backend_version')
          # Managed VM
          @running_on_managed_vm = true
          @gae_backend_name =
              fetch_gce_metadata('instance/attributes/gae_backend_name')
          @gae_backend_version =
              fetch_gce_metadata('instance/attributes/gae_backend_version')
          @service_name = APPENGINE_SERVICE
          common_labels["#{APPENGINE_SERVICE}/module_id"] = @gae_backend_name
          common_labels["#{APPENGINE_SERVICE}/version_id"] =
            @gae_backend_version
        elsif attributes.include?('job_id')
          # Dataflow
          @service_name = DATAFLOW_SERVICE
          @dataflow_job_id = fetch_gce_metadata('instance/attributes/job_id')
          common_labels["#{DATAFLOW_SERVICE}/job_id"] = @dataflow_job_id
        end
        # include GCE labels unless we're running on dataflow, which
        # uses their own labels exclusively.
        if (@service_name != DATAFLOW_SERVICE)
          common_labels["#{COMPUTE_SERVICE}/resource_type"] = 'instance'
          common_labels["#{COMPUTE_SERVICE}/resource_id"] = @vm_id
        end
      when Platform::EC2
        @service_name = EC2_SERVICE
        common_labels["#{EC2_SERVICE}/resource_type"] = 'instance'
        common_labels["#{EC2_SERVICE}/resource_id"] = @vm_id
      when Platform::OTHER
        # Use COMPUTE_SERVICE as the default environment.
        @service_name = COMPUTE_SERVICE
        common_labels["#{COMPUTE_SERVICE}/resource_type"] = 'instance'
        common_labels["#{COMPUTE_SERVICE}/resource_id"] = @vm_id
      end
    end

    def start
      super

      init_api_client

      @successful_call = false
      @timenanos_warning = false
    end

    def shutdown
      super
    end

    def format(tag, time, record)
      [tag, time, record].to_msgpack
    end

    def write(chunk)
      # Group the entries since we have to make one call per tag.
      grouped_entries = {}
      chunk.msgpack_each do |tag, *arr|
        grouped_entries[tag] = [] unless grouped_entries.key?(tag)
        grouped_entries[tag].push(arr)
      end

      grouped_entries.each do |tag, arr|
        write_log_entries_request = {
          'commonLabels' => @common_labels,
          'entries' => []
        }
        arr.each do |time, record|
          next unless record.is_a?(Hash)
          if record.key?('timestamp') &&
             record['timestamp'].is_a?(Hash) &&
             record['timestamp'].key?('seconds') &&
             record['timestamp'].key?('nanos')
            ts_secs = record['timestamp']['seconds']
            ts_nanos = record['timestamp']['nanos']
            record.delete('timestamp')
          elsif record.key?('timestampSeconds') &&
                record.key?('timestampNanos')
            ts_secs = record['timestampSeconds']
            ts_nanos = record['timestampNanos']
            record.delete('timestampSeconds')
            record.delete('timestampNanos')
          elsif record.key?('timeNanos')
            # This is deprecated since the precision is insufficient.
            # Use timestampSeconds/timestampNanos instead
            ts_secs = (record['timeNanos'] / 1_000_000_000).to_i
            ts_nanos = record['timeNanos'] % 1_000_000_000
            record.delete('timeNanos')
            unless @timenanos_warning
              # Warn the user this is deprecated, but only once to avoid spam.
              @timenanos_warning = true
              @log.warn 'timeNanos is deprecated - please use ' \
                'timestampSeconds and timestampNanos instead.'
            end
          else
            timestamp = Time.at(time)
            ts_secs = timestamp.tv_sec
            ts_nanos = timestamp.tv_nsec
          end
          entry = {
            'metadata' => {
              'serviceName' => @service_name,
              'projectId' => @project_id,
              'zone' => @zone,
              'timestamp' => {
                'seconds' => ts_secs,
                'nanos' => ts_nanos
              }
            }
          }
          if record.key?('severity')
            entry['metadata']['severity'] = parse_severity(record['severity'])
            record.delete('severity')
          else
            entry['metadata']['severity'] = 'DEFAULT'
          end

          # If a field is present in the label_map, send its value as a label
          # (mapping the field name to label name as specified in the config)
          # and do not send that field as part of the payload.
          unless label_map.nil?
            labels = {}
            @label_map.each do |field, label|
              if record.key?(field)
                labels[label] = record[field]
                record.delete(field)
              end
            end
            entry['metadata']['labels'] = labels unless labels.empty?
          end

          # use textPayload if the only remainaing key is 'message',
          # otherwise use a struct.
          if record.size == 1 && record.key?('message')
            entry['textPayload'] = record['message']
          else
            entry['structPayload'] = record
          end
          write_log_entries_request['entries'].push(entry)
        end
        # Don't send an empty request if we rejected all the entries.
        next if write_log_entries_request['entries'].empty?

        # Add a prefix to VMEngines logs to prevent namespace collisions,
        # and also escape the log name.
        log_name = CGI.escape(
          @running_on_managed_vm ? "#{APPENGINE_SERVICE}/#{tag}" : tag)
        url = 'https://logging.googleapis.com/v1beta3/projects/' \
          "#{@project_id}/logs/#{log_name}/entries:write"
        begin
          client = api_client
          request = client.generate_request(
            uri: url,
            body_object: write_log_entries_request,
            http_method: 'POST',
            authenticated: true
          )
          client.execute!(request)
          # Let the user explicitly know when the first call succeeded,
          # to aid with verification and troubleshooting.
          unless @successful_call
            @successful_call = true
            @log.info 'Successfully sent to Google Cloud Logging API.'
          end
        # Allow most exceptions to propagate, which will cause fluentd to
        # retry (with backoff), but in some cases we catch the error and
        # drop the request (we will emit a log message in those cases).
        rescue Google::APIClient::ClientError => error
          # Most ClientErrors indicate a problem with the request itself and
          # should not be retried, unless it is an authentication issue, in
          # which case we will retry the request via re-raising the exception.
          raise error if retriable_client_error?(error)
          log_write_failure(write_log_entries_request, error)
        rescue JSON::GeneratorError => error
          # This happens if the request contains illegal characters;
          # do not retry it because it will fail repeatedly.
          log_write_failure(write_log_entries_request, error)
        end
      end
    end

    private

    RETRIABLE_CLIENT_ERRORS = Set.new [
      'Invalid Credentials',
      'Request had invalid credentials.',
      'The caller does not have permission',
      'Project has not enabled the API. Please use Google Developers ' \
        'Console to activate the API for your project.',
      'Unable to fetch access token (no scopes configured?)']

    def retriable_client_error?(error)
      RETRIABLE_CLIENT_ERRORS.include?(error.message)
    end

    def log_write_failure(request, error)
      dropped = request['entries'].length
      @log.warn "Dropping #{dropped} log message(s)",
                error_class: error.class.to_s, error: error.to_s
    end

    # "enum" of Platform values
    module Platform
      OTHER = 0  # Other/unkown platform
      GCE = 1    # Google Compute Engine
      EC2 = 2    # Amazon EC2
    end

    # Determine what platform we are running on by consulting the metadata
    # service (unless the user has explicitly disabled using that).
    def detect_platform
      unless @use_metadata_service
        @log.info 'use_metadata_service is false; not detecting platform'
        return Platform::OTHER
      end

      begin
        open('http://' + METADATA_SERVICE_ADDR) do |f|
          if (f.meta['metadata-flavor'] == 'Google')
            @log.info 'Detected GCE platform'
            return Platform::GCE
          end
          if (f.meta['server'] == 'EC2ws')
            @log.info 'Detected EC2 platform'
            return Platform::EC2
          end
        end
      rescue StandardError => e
        @log.debug 'Failed to access metadata service: ', error: e
      end

      @log.info 'Unable to determine platform'
      Platform::OTHER
    end

    def fetch_gce_metadata(metadata_path)
      fail "Called fetch_gce_metadata with platform=#{@platform}" unless
        @platform == Platform::GCE
      # See https://cloud.google.com/compute/docs/metadata
      open('http://' + METADATA_SERVICE_ADDR + '/computeMetadata/v1/' +
           metadata_path, 'Metadata-Flavor' => 'Google') do |f|
        f.read
      end
    end

    def fetch_ec2_metadata
      fail "Called fetch_ec2_metadata with platform=#{@platform}" unless
        @platform == Platform::EC2
      # See http://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-instance-metadata.html
      open('http://' + METADATA_SERVICE_ADDR +
           '/latest/dynamic/instance-identity/document') do |f|
        contents = f.read
        return JSON.parse(contents)
      end
    end

    # Values permitted by the API for 'severity' (which is an enum).
    VALID_SEVERITIES = Set.new(
      %w(DEFAULT DEBUG INFO NOTICE WARNING ERROR CRITICAL ALERT EMERGENCY))

    # Translates other severity strings to one of the valid values above.
    SEVERITY_TRANSLATIONS = {
      # log4j levels (both current and obsolete).
      'WARN' => 'WARNING',
      'FATAL' => 'CRITICAL',
      'TRACE' => 'DEBUG',
      'TRACE_INT' => 'DEBUG',
      'FINE' => 'DEBUG',
      'FINER' => 'DEBUG',
      'FINEST' => 'DEBUG',
      # single-letter levels.  Note E->ERROR and D->DEBUG.
      'D' => 'DEBUG',
      'I' => 'INFO',
      'N' => 'NOTICE',
      'W' => 'WARNING',
      'E' => 'ERROR',
      'C' => 'CRITICAL',
      'A' => 'ALERT',
      # other misc. translations.
      'ERR' => 'ERROR'
    }

    def parse_severity(severity_str)
      # The API is case insensitive, but uppercase to make things simpler.
      severity = severity_str.upcase.strip

      # If the severity is already valid, just return it.
      return severity if VALID_SEVERITIES.include?(severity)

      # If the severity is an integer (string) return it as an integer,
      # truncated to the closest valid value (multiples of 100 between 0-800).
      if /\A\d+\z/.match(severity)
        begin
          numeric_severity = (severity.to_i / 100) * 100
          if numeric_severity < 0
            return 0
          elsif numeric_severity > 800
            return 800
          else
            return numeric_severity
          end
        rescue
          return 'DEFAULT'
        end
      end

      # Try to translate the severity.
      if SEVERITY_TRANSLATIONS.key?(severity)
        return SEVERITY_TRANSLATIONS[severity]
      end

      # If all else fails, use 'DEFAULT'.
      'DEFAULT'
    end

    def init_api_client
      @client = Google::APIClient.new(
        application_name: 'Fluentd Google Cloud Logging plugin',
        application_version: '0.4.3',
        retries: 1)

      if @auth_method == 'private_key'
        key = Google::APIClient::PKCS12.load_key(@private_key_path,
                                                 @private_key_passphrase)
        jwt_asserter = Google::APIClient::JWTAsserter.new(
          @private_key_email, LOGGING_SCOPE, key)
        @client.authorization = jwt_asserter.to_authorization
        @client.authorization.expiry = 3600  # 3600s is the max allowed value
      else
        @client.authorization = Google::Auth.get_application_default(
          LOGGING_SCOPE)
      end
    end

    def api_client
      unless @client.authorization.expired?
        begin
          @client.authorization.fetch_access_token!
        rescue MultiJson::ParseError
          # Workaround an issue in the API client; just re-raise a more
          # descriptive error for the user (which will still cause a retry).
          raise Google::APIClient::ClientError, 'Unable to fetch access ' \
            'token (no scopes configured?)'
        end
      end
      @client
    end
  end
end
