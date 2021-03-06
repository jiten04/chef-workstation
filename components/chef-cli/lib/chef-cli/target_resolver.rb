require "chef-cli/target_host"
require "chef-cli/error"

module ChefCLI
  class TargetResolver
    # IDeally, we'd base this on the actual current screen height
    MAX_EXPANDED_TARGETS = 24

    def initialize(unparsed_target, conn_options)
      @unparsed_target = unparsed_target
      @split_targets = unparsed_target.split(",")
      @conn_options = conn_options
    end

    # Returns the list of targets as an array of strings, after expanding
    # them to account for ranges embedded in the target.
    def targets
      return @targets unless @targets.nil?
      hostnames = []
      @split_targets.each do |target|
        hostnames = (hostnames | expand_targets(target_to_valid_url(target)))
      end
      @targets = hostnames.map { |host| TargetHost.new(host, @conn_options) }
    end

    def expand_targets(target)
      @current_target = target # Hold onto this for error reporting
      do_parse([target.downcase])
    end

    # This method will prefix the target with 'ssh://' if no prefix
    # is present, and replace the password (if present) with
    # its www-form-component encoded value.
    # This allows it to be further passed into Train, which knows
    # how to deal with www-form encoded passwords.
    def target_to_valid_url(target)
      if target =~ /^(.+?):\/\/(.*)/
        # We'll store the existing prefix to avoid it interfering
        # with the check further below.
        prefix = "#{$1}://"
        target = $2
      else
        prefix = "ssh://"
      end

      credentials = ""
      host = target
      # Default greedy-scan of the regex means that
      # $2 will resolve to content after the final "@"
      if target =~ /(.*)@(.*)/
        credentials = $1
        host = $2
        # We'll use a non-greedy match to grab everthinmg up to the first ':'
        # as username if there is no :, credentials is just the username
        if credentials =~ /(.+?):(.*)/
          credentials = "#{$1}:#{URI.encode_www_form_component($2)}@"
        else
          credentials = "#{credentials}@"
        end
      end
      "#{prefix}#{credentials}#{host}"
    end

    private

    # A string matching PREFIX[x:y]POSTFIX:
    # POSTFIX can contain further ranges itself
    # This uses a greedy match (.*) to get include every character
    # up to the last "[" in PREFIX
    # $1 - prefix; $2 - x, $3 - y, $4 unproccessed/remaining text
    TARGET_WITH_RANGE = /^(.*)\[([\p{Alnum}]+):([\p{Alnum}]+)\](.*)/

    def do_parse(targets, depth = 0)
      if depth > 2
        raise TooManyRanges.new(@current_target)
      end
      new_targets = []
      done = false
      targets.each do |target|
        if TARGET_WITH_RANGE =~ target
          # $1 - prefix; $2 - x, $3 - y, $4 unprocessed/remaining text
          expand_range(new_targets, $1, $2, $3, $4)
        else
          done = true
          new_targets << target
        end
      end

      if done
        new_targets
      else
        do_parse(new_targets, depth + 1)
      end
    end

    def expand_range(dest, prefix, start, stop, suffix)
      prefix ||= ""
      suffix ||= ""
      start_is_int = Integer(start) >= 0 rescue false
      stop_is_int = Integer(stop) >= 0 rescue false

      if (start_is_int && !stop_is_int) || (stop_is_int && !start_is_int)
        raise InvalidRange.new(@current_target, "[#{start}:#{stop}]")
      end

      # Ensure that a numeric range doesn't get created as a string, which
      # would make the created Range further below fail to iterate for some values
      # because of ASCII sorting.
      if start_is_int
        start = Integer(start)
      end

      if stop_is_int
        stop = Integer(stop)
      end

      # For range to iterate correctly, the values must
      # be low,high
      if start > stop
        temp = stop; stop = start; start = temp
      end
      Range.new(start, stop).each do |value|
        # Ranges will resolve only numbers and letters,
        # not other ascii characters that happen to fall between.
        if start_is_int || /^[a-z0-9]/ =~ value
          dest << "#{prefix}#{value}#{suffix}"
        end
        # Stop expanding as soon as we go over limit to prevent
        # making the user wait for a massive accidental expansion
        if dest.length > MAX_EXPANDED_TARGETS
          raise TooManyTargets.new(@split_targets.length, MAX_EXPANDED_TARGETS)
        end
      end
    end

    class InvalidRange < ErrorNoLogs
      def initialize(unresolved_target, given_range)
        super("CHEFRANGE001", unresolved_target, given_range)
      end
    end
    class TooManyRanges < ErrorNoLogs
      def initialize(unresolved_target)
        super("CHEFRANGE002", unresolved_target)
      end
    end

    class TooManyTargets < ErrorNoLogs
      def initialize(num_top_level_targets, max_targets)
        super("CHEFRANGE003", num_top_level_targets, max_targets)
      end
    end
  end
end
