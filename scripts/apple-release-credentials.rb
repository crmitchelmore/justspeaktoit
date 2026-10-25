# frozen_string_literal: true

require 'open3'
require 'openssl'
require 'timeout'

module AppleRelease
  class CredentialError < StandardError; end

  # Capture both streams in memory. Never invoke a shell, print CLI diagnostics,
  # or let an unattended desktop-unlock prompt hold the release indefinitely.
  class OpReader
    def initialize(spawn: Open3.method(:popen3), timeout: 30)
      @spawn, @timeout = spawn, timeout
    end

    def read(reference)
      @spawn.call('op', 'read', '--no-newline', reference) do |input, output, errors, process|
        input.close
        readers = [output, errors].map do |stream|
          Thread.new { stream.read rescue '' }
        end
        begin
          Timeout.timeout(@timeout) do
            status = process.value
            value = readers[0].value
            readers[1].value # Drain stderr, but never expose its contents.
            raise CredentialError unless status.success? && !value.strip.empty?
            value
          end
        ensure
          stop_owned_process(process)
          [output, errors].each { |stream| stream.close unless stream.closed? }
          readers.each { |reader| reader.kill if reader.alive?; reader.join }
        end
      end
    rescue StandardError
      raise CredentialError, 'Unable to read 1Password release credentials', cause: nil
    end

    private

    def stop_owned_process(process)
      return if process.join(0)
      Process.kill('TERM', process.pid)
      Process.kill('KILL', process.pid) unless process.join(0.25)
      process.value # Reap only the child this read created.
    rescue Errno::ESRCH
      process.value
    end
  end

  module VaultCredentials
    REFERENCES = %w[
      APP_STORE_CONNECT_KEY_ID_REF
      APP_STORE_CONNECT_ISSUER_ID_REF
      APP_STORE_CONNECT_PRIVATE_KEY_REF
    ].freeze

    def self.load(env:, reader:)
      refs = REFERENCES.map { |name| env[name] }
      unless refs.all? { |ref| valid_reference?(ref) }
        raise CredentialError, 'Configure all three 1Password release credential references'
      end
      key_id, issuer, pem = refs.map { |ref| reader.read(ref) }
      key = OpenSSL::PKey.read(pem)
      unless key.is_a?(OpenSSL::PKey::EC) && key.private? && key.group.curve_name == 'prime256v1'
        raise CredentialError, 'Invalid 1Password release credentials'
      end
      raise CredentialError, 'Invalid 1Password release credentials' if key_id.strip.empty? || issuer.strip.empty?
      [key_id.strip, issuer.strip, key]
    rescue StandardError
      raise CredentialError, 'Unable to load 1Password release credentials; check references and unlock access', cause: nil
    end

    def self.valid_reference?(reference)
      return false unless reference.is_a?(String) && reference.start_with?('op://')
      return false if reference.match?(/[\r\n\0]/)
      parts = reference.delete_prefix('op://').split('/', -1)
      parts.length >= 3 && parts.all? { |part| !part.strip.empty? }
    end
  end
end
