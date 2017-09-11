# encoding: utf-8
# frozen_string_literal: true

require 'monitor'
require 'forwardable'

require_relative '../spinner'

module TTY
  class Spinner
    # Used for managing multiple terminal spinners
    #
    # @api public
    class Multi
      include Enumerable
      include MonitorMixin

      extend Forwardable

      def_delegators :@spinners, :each, :empty?, :length

      DEFAULT_INSET = {
        top:    Gem.win_platform? ? '+ '   : "\u250c ",
        middle: Gem.win_platform? ? '|-- ' : "\u251c\u2500\u2500 ",
        bottom: Gem.win_platform? ? '|__ ' : "\u2514\u2500\u2500 "
      }.freeze

      # The current count of all rendered rows
      #
      # @api public
      attr_reader :rows

      # Initialize a multispinner
      #
      # @example
      #   spinner = TTY::Spinner::Multi.new
      #
      # @param [String] message
      #   the optional message to print in front of the top level spinner
      #
      # @param [Hash] options
      # @option options [Hash] :style
      #   keys :top :middle and :bottom can contain Strings that are used to
      #   indent the spinners. Ignored if message is blank
      # @option options [Object] :output
      #   the object that responds to print call defaulting to stderr
      # @option options [Boolean] :hide_cursor
      #   display or hide cursor
      # @option options [Boolean] :clear
      #   clear ouptut when finished
      # @option options [Float] :interval
      #   the interval for auto spinning
      #
      # @api public
      def initialize(*args)
        super()
        @options = args.last.is_a?(::Hash) ? args.pop : {}
        message = args.empty? ? nil : args.pop
        @inset_opts  = @options.delete(:style) { DEFAULT_INSET }
        @rows        = 0
        @spinners    = []
        @top_spinner = nil
        @last_spin_at = nil
        unless message.nil?
          @top_spinner = register(message, observable: false, row: next_row)
        end

        @callbacks = {
          success: [],
          error:   [],
          done:    []
        }
      end

      # Register a new spinner
      #
      # @param [String] pattern
      #   the pattern used for creating spinner
      #
      # @api public
      def register(pattern, options = {}, &job)
        observable = options.delete(:observable) { true }
        spinner = TTY::Spinner.new(pattern, @options.merge(options))

        synchronize do
          spinner.add_multispinner(self)
          spinner.job(&job) if block_given?
          observe(spinner) if observable
          @spinners << spinner
          if @top_spinner
            @spinners.each { |sp| sp.redraw_indent if sp.spinning? || sp.done? }
          end
        end

        spinner
      end

      # Increase a row count
      #
      # @api public
      def next_row
        synchronize do
          @rows += 1
        end
      end

      # Get the top level spinner if it exists
      #
      # @return [TTY::Spinner] the top level spinner
      #
      # @api public
      def top_spinner
        raise "No top level spinner" if @top_spinner.nil?

        @top_spinner
      end

      # Auto spin the top level spinner & all child spinners
      # that have scheduled jobs
      #
      # @api public
      def auto_spin
        raise "No top level spinner" if @top_spinner.nil?

        @top_spinner.auto_spin
        jobs = []
        @spinners.each do |spinner|
          if spinner.job?
            spinner.auto_spin
            jobs << Thread.new { spinner.execute_job }
          end
        end
        jobs.each(&:join)
      end

      # Perform a single spin animation
      #
      # @api public
      def spin
        raise "No top level spinner" if @top_spinner.nil?

        @top_spinner.spin
      end

      # Pause all spinners
      #
      # @api public
      def pause
        @spinners.dup.each(&:pause)
      end

      # Resume all spinners
      #
      # @api public
      def resume
        @spinners.dup.each(&:resume)
      end

      # Find the number of characters to move into the line
      # before printing the spinner
      #
      # @param [TTY::Spinner] spinner
      #   the spinner for which line inset is calculated
      #
      # @return [String]
      #   the inset
      #
      # @api public
      def line_inset(spinner)
        return '' if @top_spinner.nil?

        case spinner
        when @top_spinner
          @inset_opts[:top]
        when @spinners.last
          @inset_opts[:bottom]
        else
          @inset_opts[:middle]
        end
      end

      # Check if all spinners are done
      #
      # @return [Boolean]
      #
      # @api public
      def done?
        synchronize do
          (@spinners - [@top_spinner]).all?(&:done?)
        end
      end

      # Check if all spinners succeeded
      #
      # @return [Boolean]
      #
      # @api public
      def success?
        synchronize do
          (@spinners - [@top_spinner]).all?(&:success?)
        end
      end

      # Check if any spinner errored
      #
      # @return [Boolean]
      #
      # @api public
      def error?
        synchronize do
          (@spinners - [@top_spinner]).any?(&:error?)
        end
      end

      # Stop all spinners
      #
      # @api public
      def stop
        @spinners.dup.each(&:stop)
      end

      # Stop all spinners with success status
      #
      # @api public
      def success
        @spinners.dup.each(&:success)
      end

      # Stop all spinners with error status
      #
      # @api public
      def error
        @spinners.dup.each(&:error)
      end

      # Listen on event
      #
      # @api public
      def on(key, &callback)
        unless @callbacks.key?(key)
          raise ArgumentError, "The event #{key} does not exist. "\
                               " Use :success, :error, or :done instead"
        end
        @callbacks[key] << callback
        self
      end

      private

      def emit(key, *args)
        @callbacks[key].each do |block|
          block.call(*args)
        end
      end

      # Observe spinner for events to notify top spinner of current state
      #
      # @param [TTY::Spinner] spinner
      #   the spinner to listen to for events
      #
      # @api private
      def observe(spinner)
        spinner.on(:success, &success_handler)
               .on(:error, &error_handler)
               .on(:done, &done_handler)
      end

      # Handle the success state
      #
      # @api private
      def success_handler
        proc do
          if success?
            @top_spinner.success if @top_spinner
            emit(:success)
          end
        end
      end

      # Handle the error state
      #
      # @api private
      def error_handler
        proc do
          if error?
            @top_spinner.error if @top_spinner
            @fired ||= emit(:error) # fire once
          end
        end
      end

      # Handle the done state
      #
      # @api private
      def done_handler
        proc do
          if done?
            @top_spinner.stop if @top_spinner
            emit(:done)
          end
        end
      end
    end # MultiSpinner
  end # Spinner
end # TTY
