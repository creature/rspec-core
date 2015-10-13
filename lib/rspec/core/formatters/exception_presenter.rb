# encoding: utf-8
module RSpec
  module Core
    module Formatters
      # @private
      class ExceptionPresenter
        attr_reader :exception, :example, :description, :message_color,
                    :detail_formatter, :extra_detail_formatter, :backtrace_formatter
        private :message_color, :detail_formatter, :extra_detail_formatter, :backtrace_formatter

        def initialize(exception, example, options={})
          @exception               = exception
          @example                 = example
          @message_color           = options.fetch(:message_color)          { RSpec.configuration.failure_color }
          @description             = options.fetch(:description_formatter)  { Proc.new { example.full_description } }.call(self)
          @detail_formatter        = options.fetch(:detail_formatter)       { Proc.new {} }
          @extra_detail_formatter  = options.fetch(:extra_detail_formatter) { Proc.new {} }
          @backtrace_formatter     = options.fetch(:backtrace_formatter)    { RSpec.configuration.backtrace_formatter }
          @indentation             = options.fetch(:indentation, 2)
          @skip_shared_group_trace = options.fetch(:skip_shared_group_trace, false)
          @failure_lines           = options[:failure_lines]
        end

        def message_lines
          add_shared_group_lines(failure_lines, Notifications::NullColorizer)
        end

        def colorized_message_lines(colorizer=::RSpec::Core::Formatters::ConsoleCodes)
          add_shared_group_lines(failure_lines, colorizer).map do |line|
            colorizer.wrap line, message_color
          end
        end

        def formatted_backtrace(exception=@exception)
          backtrace_formatter.format_backtrace((exception.backtrace || []), example.metadata) +
            formatted_cause(exception)
        end

        if RSpec::Support::RubyFeatures.supports_exception_cause?
          def formatted_cause(exception)
            last_cause = final_exception(exception)
            cause = []

            if exception.cause
              cause << '------------------'
              cause << '--- Caused by: ---'
              cause << "#{exception_class_name(last_cause)}:" unless exception_class_name(last_cause) =~ /RSpec/

              encoded_string(last_cause.message.to_s).split("\n").each do |line|
                cause << "  #{line}"
              end

              cause << ("  #{backtrace_formatter.format_backtrace(last_cause.backtrace, example.metadata).first}")
            end

            cause
          end
        else
          # :nocov:
          def formatted_cause(_)
            []
          end
          # :nocov:
        end

        def colorized_formatted_backtrace(colorizer=::RSpec::Core::Formatters::ConsoleCodes)
          formatted_backtrace.map do |backtrace_info|
            colorizer.wrap "# #{backtrace_info}", RSpec.configuration.detail_color
          end
        end

        def fully_formatted(failure_number, colorizer=::RSpec::Core::Formatters::ConsoleCodes)
          alignment_basis = "#{' ' * @indentation}#{failure_number}) "
          indentation = ' ' * alignment_basis.length

          "\n#{alignment_basis}#{description_and_detail(colorizer, indentation)}" \
          "\n#{formatted_message_and_backtrace(colorizer, indentation)}" \
          "#{extra_detail_formatter.call(failure_number, colorizer, indentation)}"
        end

        def failure_slash_error_line
          @failure_slash_error_line ||= "Failure/Error: #{read_failed_line.strip}"
        end

      private

        def final_exception(exception)
          if exception.cause
            final_exception(exception.cause)
          else
            exception
          end
        end

        def description_and_detail(colorizer, indentation)
          detail = detail_formatter.call(example, colorizer, indentation)
          return (description || detail) unless description && detail
          "#{description}\n#{indentation}#{detail}"
        end

        if String.method_defined?(:encoding)
          def encoding_of(string)
            string.encoding
          end

          def encoded_string(string)
            RSpec::Support::EncodedString.new(string, Encoding.default_external)
          end
        else # for 1.8.7
          # :nocov:
          def encoding_of(_string)
          end

          def encoded_string(string)
            RSpec::Support::EncodedString.new(string)
          end
          # :nocov:
        end

        def exception_class_name(exception=@exception)
          name = exception.class.name.to_s
          name = "(anonymous error class)" if name == ''
          name
        end

        def failure_lines
          @failure_lines ||=
            begin
              lines = []
              lines << failure_slash_error_line unless (description == failure_slash_error_line)
              lines << "#{exception_class_name}:" unless exception_class_name =~ /RSpec/
              encoded_string(exception.message.to_s).split("\n").each do |line|
                lines << "  #{line}"
              end
              lines
            end
        end

        def add_shared_group_lines(lines, colorizer)
          return lines if @skip_shared_group_trace

          example.metadata[:shared_group_inclusion_backtrace].each do |frame|
            lines << colorizer.wrap(frame.description, RSpec.configuration.default_color)
          end

          lines
        end

        def read_failed_line
          matching_line = find_failed_line
          unless matching_line
            return "Unable to find matching line from backtrace"
          end

          file_path, line_number = matching_line.match(/(.+?):(\d+)(|:\d+)/)[1..2]

          if File.exist?(file_path)
            File.readlines(file_path)[line_number.to_i - 1] ||
              "Unable to find matching line in #{file_path}"
          else
            "Unable to find #{file_path} to read failed line"
          end
        rescue SecurityError
          "Unable to read failed line"
        end

        def find_failed_line
          line_regex = RSpec.configuration.in_project_source_dir_regex

          exception_backtrace.find do |line|
            File.expand_path(line) =~ line_regex
          end || exception_backtrace.first
        end

        def formatted_message_and_backtrace(colorizer, indentation)
          lines = colorized_message_lines(colorizer) + colorized_formatted_backtrace(colorizer)

          formatted = ""

          lines.each do |line|
            formatted << RSpec::Support::EncodedString.new("#{indentation}#{line}\n", encoding_of(formatted))
          end

          formatted
        end

        def exception_backtrace
          exception.backtrace || []
        end

        # @private
        # Configuring the `ExceptionPresenter` with the right set of options to handle
        # pending vs failed vs skipped and aggregated (or not) failures is not simple.
        # This class takes care of building an appropriate `ExceptionPresenter` for the
        # provided example.
        class Factory
          def build
            ExceptionPresenter.new(@exception, @example, options)
          end

        private

          def initialize(example)
            @example          = example
            @execution_result = example.execution_result
            @exception        = if @execution_result.status == :pending
                                  @execution_result.pending_exception
                                else
                                  @execution_result.exception
                                end
          end

          def options
            with_multiple_error_options_as_needed(@exception, pending_options || {})
          end

          def pending_options
            if @execution_result.pending_fixed?
              {
                :description_formatter => Proc.new { "#{@example.full_description} FIXED" },
                :message_color         => RSpec.configuration.fixed_color,
                :failure_lines         => [
                  "Expected pending '#{@execution_result.pending_message}' to fail. No Error was raised."
                ]
              }
            elsif @execution_result.status == :pending
              {
                :message_color    => RSpec.configuration.pending_color,
                :detail_formatter => PENDING_DETAIL_FORMATTER
              }
            end
          end

          def with_multiple_error_options_as_needed(exception, options)
            return options unless multiple_exceptions_error?(exception)

            options = options.merge(
              :failure_lines          => [],
              :extra_detail_formatter => sub_failure_list_formatter(exception, options[:message_color]),
              :detail_formatter       => multiple_exception_summarizer(exception,
                                                                       options[:detail_formatter],
                                                                       options[:message_color])
            )

            options[:description_formatter] &&= Proc.new {}

            return options unless exception.aggregation_metadata[:hide_backtrace]
            options[:backtrace_formatter] = EmptyBacktraceFormatter
            options
          end

          def multiple_exceptions_error?(exception)
            MultipleExceptionError::InterfaceTag === exception
          end

          def multiple_exception_summarizer(exception, prior_detail_formatter, color)
            lambda do |example, colorizer, indentation|
              summary = if exception.aggregation_metadata[:hide_backtrace]
                          # Since the backtrace is hidden, the subfailures will come
                          # immediately after this, and using `:` will read well.
                          "Got #{exception.exception_count_description}:"
                        else
                          # The backtrace comes after this, so using a `:` doesn't make sense
                          # since the failures may be many lines below.
                          "#{exception.summary}."
                        end

              summary = colorizer.wrap(summary, color || RSpec.configuration.failure_color)
              return summary unless prior_detail_formatter
              "#{prior_detail_formatter.call(example, colorizer, indentation)}\n#{indentation}#{summary}"
            end
          end

          def sub_failure_list_formatter(exception, message_color)
            common_backtrace_truncater = CommonBacktraceTruncater.new(exception)

            lambda do |failure_number, colorizer, indentation|
              exception.all_exceptions.each_with_index.map do |failure, index|
                options = with_multiple_error_options_as_needed(
                  failure,
                  :description_formatter   => :failure_slash_error_line.to_proc,
                  :indentation             => indentation.length,
                  :message_color           => message_color || RSpec.configuration.failure_color,
                  :skip_shared_group_trace => true
                )

                failure   = common_backtrace_truncater.with_truncated_backtrace(failure)
                presenter = ExceptionPresenter.new(failure, @example, options)
                presenter.fully_formatted("#{failure_number}.#{index + 1}", colorizer)
              end.join
            end
          end

          # @private
          # Used to prevent a confusing backtrace from showing up from the `aggregate_failures`
          # block declared for `:aggregate_failures` metadata.
          module EmptyBacktraceFormatter
            def self.format_backtrace(*)
              []
            end
          end

          # @private
          class CommonBacktraceTruncater
            def initialize(parent)
              @parent = parent
            end

            def with_truncated_backtrace(child)
              child_bt  = child.backtrace
              parent_bt = @parent.backtrace
              return child if child_bt.nil? || child_bt.empty? || parent_bt.nil?

              index_before_first_common_frame = -1.downto(-child_bt.size).find do |index|
                parent_bt[index] != child_bt[index]
              end

              return child if index_before_first_common_frame == -1

              child = child.dup
              child.set_backtrace(child_bt[0..index_before_first_common_frame])
              child
            end
          end
        end

        # @private
        PENDING_DETAIL_FORMATTER = Proc.new do |example, colorizer|
          colorizer.wrap("# #{example.execution_result.pending_message}", :detail)
        end
      end
    end

    # Provides a single exception instance that provides access to
    # multiple sub-exceptions. This is used in situations where a single
    # individual spec has multiple exceptions, such as one in the `it` block
    # and one in an `after` block.
    class MultipleExceptionError < StandardError
      # @private
      # Used so there is a common module in the ancestor chain of this class
      # and `RSpec::Expectations::MultipleExpectationsNotMetError`, which allows
      # code to detect exceptions that are instances of either, without first
      # checking to see if rspec-expectations is loaded.
      module InterfaceTag
        # Appends the provided exception to the list.
        # @param exception [Exception] Exception to append to the list.
        # @private
        def add(exception)
          # `PendingExampleFixedError` can be assigned to an example that initially has no
          # failures, but when the `aggregate_failures` around hook completes, it notifies of
          # a failure. If we do not ignore `PendingExampleFixedError` it would be surfaced to
          # the user as part of a multiple exception error, which is undesirable. While it's
          # pretty weird we handle this here, it's the best solution I've been able to come
          # up with, and `PendingExampleFixedError` always represents the _lack_ of any exception
          # so clearly when we are transitioning to a `MultipleExceptionError`, it makes sense to
          # ignore it.
          return if Pending::PendingExampleFixedError === exception

          all_exceptions << exception

          if exception.class.name =~ /RSpec/
            failures << exception
          else
            other_errors << exception
          end
        end

        # Provides a way to force `ex` to be something that satisfies the multiple
        # exception error interface. If it already satisfies it, it will be returned;
        # otherwise it will wrap it in a `MultipleExceptionError`.
        # @private
        def self.for(ex)
          return ex if self === ex
          MultipleExceptionError.new(ex)
        end
      end

      include InterfaceTag

      # @return [Array<Exception>] The list of failures.
      attr_reader :failures

      # @return [Array<Exception>] The list of other errors.
      attr_reader :other_errors

      # @return [Array<Exception>] The list of failures and other exceptions, combined.
      attr_reader :all_exceptions

      # @return [Hash] Metadata used by RSpec for formatting purposes.
      attr_reader :aggregation_metadata

      # @return [nil] Provided only for interface compatibility with
      #   `RSpec::Expectations::MultipleExpectationsNotMetError`.
      attr_reader :aggregation_block_label

      # @param exceptions [Array<Exception>] The initial list of exceptions.
      def initialize(*exceptions)
        super()

        @failures                = []
        @other_errors            = []
        @all_exceptions          = []
        @aggregation_metadata    = { :hide_backtrace => true }
        @aggregation_block_label = nil

        exceptions.each { |e| add e }
      end

      # @return [String] Combines all the exception messages into a single string.
      # @note RSpec does not actually use this -- instead it formats each exception
      #   individually.
      def message
        all_exceptions.map(&:message).join("\n\n")
      end

      # @return [String] A summary of the failure, including the block label and a count of failures.
      def summary
        "Got #{exception_count_description}"
      end

      # return [String] A description of the failure/error counts.
      def exception_count_description
        failure_count = Formatters::Helpers.pluralize(failures.size, "failure")
        return failure_count if other_errors.empty?
        error_count = Formatters::Helpers.pluralize(other_errors.size, "other error")
        "#{failure_count} and #{error_count}"
      end
    end
  end
end
