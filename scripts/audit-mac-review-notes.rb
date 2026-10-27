#!/usr/bin/env ruby
# frozen_string_literal: true

require 'optparse'
require_relative 'release-apple'

module AppleRelease
  module MacReviewNotesCLI
    def self.client(env: ENV)
      case env['APP_STORE_CONNECT_CREDENTIAL_SOURCE']
      when '1password'
        # The existing client validates explicit vault references; no fallback.
      when 'environment'
        raise MacReviewNotes::Error, 'explicit_ci_key_path_required' if env['APP_STORE_CONNECT_KEY_PATH'].to_s.empty?
      else
        raise MacReviewNotes::Error, 'explicit_credential_source_required'
      end
      Client.new(env: env)
    end

    def self.parse(argv)
      options = {mode: 'audit'}
      parser = OptionParser.new do |flags|
        flags.on('--mode MODE', %w[audit repair]) { |value| options[:mode] = value }
        flags.on('--version-id ID') { |value| options[:version_id] = value }
        flags.on('--expected-notes-sha256 HASH') { |value| options[:hash] = value }
      end
      parser.parse!(argv)
      raise MacReviewNotes::Error, 'unexpected_arguments' unless argv.empty?
      if options[:mode] == 'repair' && (!options[:version_id] || !options[:hash])
        raise MacReviewNotes::Error, 'repair_selection_required'
      end
      if options[:version_id] && !options[:version_id].match?(/\A[A-Za-z0-9][A-Za-z0-9-]{0,127}\z/)
        raise MacReviewNotes::Error, 'invalid_version_id'
      end
      if options[:hash] && !options[:hash].match?(/\A[0-9a-f]{64}\z/)
        raise MacReviewNotes::Error, 'invalid_expected_notes_hash'
      end
      raise MacReviewNotes::Error, 'unexpected_audit_hash' if options[:mode] == 'audit' && options[:hash]
      options
    end

    def self.validate(argv, errors: $stderr)
      parse(argv)
      0
    rescue StandardError
      errors.puts('Mac review notes: invalid_inputs')
      1
    end

    def self.run(argv, client_factory: -> { client }, output: $stdout, errors: $stderr)
      options = parse(argv)
      notes = MacReviewNotes.new(client: client_factory.call, train: 'stable')
      result = if options[:mode] == 'repair'
        [notes.repair(version_id: options[:version_id], expected_notes_hash: options[:hash])]
      else
        notes.audit(version_id: options[:version_id])
      end
      output.puts(JSON.generate(result))
      0
    rescue MacReviewNotes::Error => error
      errors.puts("Mac review notes: #{error.message}")
      1
    rescue StandardError
      errors.puts('Mac review notes: request_or_arguments_failed')
      1
    end
  end
end

exit AppleRelease::MacReviewNotesCLI.run(ARGV) if $PROGRAM_NAME == __FILE__
