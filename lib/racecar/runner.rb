module Racecar
  class Runner
    attr_reader :consumer_name, :config, :logger

    def initialize(consumer_name, config:, logger:)
      @consumer_name, @config, @logger = consumer_name, config, logger
    end

    def run
      consumer_class = Kernel.const_get(consumer_name)

      kafka = Kafka.new(
        client_id: config.client_id,
        seed_brokers: config.brokers,
        logger: logger,
        connect_timeout: config.connect_timeout,
        socket_timeout: config.socket_timeout,
      )

      group_id = consumer_class.group_id

      group_id ||= [
        # Configurable and optional prefix:
        config.group_id_prefix,

        # MyFunnyConsumer => my-funny-consumer
        consumer_class.name.gsub(/[a-z][A-Z]/) {|str| str[0] << "-" << str[1] }.downcase,
      ].compact.join("")

      consumer = kafka.consumer(
        group_id: group_id,
        offset_commit_interval: config.offset_commit_interval,
        offset_commit_threshold: config.offset_commit_threshold,
        heartbeat_interval: config.heartbeat_interval,
      )

      # Stop the consumer on SIGINT and SIGQUIT.
      trap("QUIT") { consumer.stop }
      trap("INT") { consumer.stop }

      consumer_class.subscriptions.each do |subscription|
        topic = subscription.topic
        start_from_beginning = subscription.start_from_beginning

        consumer.subscribe(topic, start_from_beginning: start_from_beginning)
      end

      consumer_object = consumer_class.new

      # The maximum time we're willing to wait for new messages to arrive at the broker
      # when long-polling.
      max_wait_time = consumer_class.max_wait_time || config.default_max_wait_time

      begin
        consumer.each_message(max_wait_time: max_wait_time) do |message|
          consumer_object.process(message)
        end
      rescue Kafka::ProcessingError => e
        @logger.error "Error processing partition #{e.topic}/#{e.partition} at offset #{e.offset}"

        if config.pause_timeout > 0
          # Pause fetches from the partition. We'll continue processing the other partitions in the topic.
          # The partition is automatically resumed after the specified timeout, and will continue where we
          # left off.
          @logger.warn "Pausing partition #{e.topic}/#{e.partition} for #{config.pause_timeout} seconds"
          consumer.pause(e.topic, e.partition, timeout: config.pause_timeout)
        end

        config.error_handler.call(e.cause, {
          topic: e.topic,
          partition: e.partition,
          offset: e.offset,
        })

        # Restart the consumer loop.
        retry
      rescue StandardError => e
        error = "#{e.class}: #{e.message}\n" + e.backtrace.join("\n")
        @logger.error "Consumer thread crashed: #{error}"

        config.error_handler.call(e)
      end

      @logger.info "Gracefully shutting down"
    end
  end
end