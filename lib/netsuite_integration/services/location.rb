module NetsuiteIntegration
    module Services
      class Location < Base
        attr_reader :poll_param

        def initialize(config, poll_param = 'netsuite_last_updated_after')
          super config
          @poll_param = poll_param
        end

        def latest
          search
        end

        private

          def search
            NetSuite::Records::Location.search({criteria: {basic: basic_criteria},preferences: default_preferences}).results
          end

          def default_preferences
            {
              pageSize: 1000,
              bodyFieldsOnly: true
            }
          end

          def basic_criteria
            [
              {
                field: 'isInactive',
                value: 'false'
              }
            ]
          end

          def time_now
            Time.now.utc
          end

          def last_updated_after
            Time.parse(config.fetch(poll_param)).iso8601
          end
      end
    end
  end