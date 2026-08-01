# frozen_string_literal: true

# Interpret only the Vagrant command-line choices that affect whether MongoDB
# can run. Keeping this parser independent of Vagrant makes its edge cases easy
# to unit test without loading providers or connecting to a guest.
module Ubuntu2604CommandPolicy
  COMMANDS = %w[provision reload resume up validate].freeze
  MONGODB_PROVISIONER_SELECTORS = %w[mongodb shell].freeze

  module_function

  def command(arguments)
    arguments.find { |argument| COMMANDS.include?(argument) }
  end

  def provisioner_selection(arguments)
    selections = []
    arguments.each_with_index do |argument, index|
      if argument == "--provision-with"
        selections.concat(arguments.fetch(index + 1, "").split(","))
      elsif argument.start_with?("--provision-with=")
        selections.concat(argument.split("=", 2).fetch(1).split(","))
      end
    end
    selections.map(&:strip).reject(&:empty?).uniq
  end

  def mongodb_secret_required?(arguments, mongodb_enabled:)
    return false unless mongodb_enabled

    vagrant_command = command(arguments)
    return false unless %w[provision reload resume up].include?(vagrant_command)
    return false if arguments.include?("--no-provision")

    selected = provisioner_selection(arguments)
    provisioning_requested = vagrant_command == "provision" ||
      vagrant_command == "up" ||
      arguments.include?("--provision") ||
      !selected.empty?
    return false unless provisioning_requested

    # No selection means every eligible provisioner may run. Selecting by the
    # generic `shell` type also includes the named MongoDB shell provisioner.
    selected.empty? || !(selected & MONGODB_PROVISIONER_SELECTORS).empty?
  end
end
