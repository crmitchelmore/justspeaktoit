# frozen_string_literal: true

require 'openssl'

module AppleRelease
  class CredentialError < StandardError
    MESSAGES = {
      references: 'Configure all three 1Password release credential references',
      unavailable: 'Unable to read 1Password release credentials; check unlocked access',
      timeout: '1Password release credential read timed out; check unlocked access',
      output_limit: '1Password release credential output exceeded its limit',
      invalid_value: '1Password release credentials contain an empty or invalid value',
      invalid_key: '1Password release credentials require a private P-256 key',
      source: 'Unsupported Apple release credential source'
    }.freeze
    attr_reader :reason
    def initialize(reason = :unavailable)
      @reason = reason
      super(MESSAGES.fetch(reason))
    end
  end

  # Keep bounded output in memory and discard diagnostics. Never invoke a shell,
  # or let an unattended desktop-unlock prompt hold the release indefinitely.
  class OpReader
    MAX_OUTPUT_BYTES = 64 * 1024
    MAX_ERROR_BYTES = 64 * 1024
    Child = Struct.new(:pid, :status, :reaped)

    def initialize(spawn: Process.method(:spawn), timeout: 30)
      @spawn, @timeout = spawn, timeout
    end

    def read(reference)
      read_owned(reference)
    rescue CredentialError => error
      raise CredentialError.new(error.reason), cause: nil
    rescue StandardError
      raise CredentialError.new, cause: nil
    end

    private

    def read_owned(reference)
      pipes = []
      child = nil
      output, output_writer = IO.pipe
      pipes.concat([output, output_writer])
      errors, error_writer = IO.pipe
      pipes.concat([errors, error_writer])
      deadline = monotonic + @timeout
      pid = @spawn.call('op', 'read', '--no-newline', reference,
        in: File::NULL, out: output_writer, err: error_writer)
      child = Child.new(pid, nil, false)
      [output_writer, error_writer].each(&:close)
      value = drain(child, output, errors, deadline)
      raise CredentialError unless child.status.success?
      raise CredentialError.new(:invalid_value) if value.strip.empty?
      value
    ensure
      begin
        stop_owned_process(child) if child
      ensure
        pipes&.each { |pipe| pipe.close unless pipe.closed? }
      end
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def drain(child, output, errors, deadline)
      streams = [output, errors]
      value = ''.b
      error_bytes = 0
      until child.reaped && streams.empty?
        poll(child)
        remaining = deadline - monotonic
        raise CredentialError.new(:timeout) if remaining <= 0
        ready = IO.select(streams, nil, nil, [remaining, 0.05].min)
        next unless ready
        ready.first.each do |stream|
          chunk = stream.read_nonblock(4096, exception: false)
          if chunk.nil?
            streams.delete(stream)
          elsif chunk != :wait_readable
            if stream == output
              raise CredentialError.new(:output_limit) if value.bytesize + chunk.bytesize > MAX_OUTPUT_BYTES
              value << chunk
            else
              error_bytes += chunk.bytesize # Count and discard diagnostics, never retain them.
              raise CredentialError.new(:output_limit) if error_bytes > MAX_ERROR_BYTES
            end
          end
        end
      end
      value
    end

    # This control thread is the sole reaper. An exited, unreaped child keeps
    # its PID reserved; once reaped, no cleanup path may signal that PID.
    def poll(child)
      return child.status if child.reaped
      result = Process.waitpid2(child.pid, Process::WNOHANG)
      if result
        child.status = result.last
        child.reaped = true
      end
      child.status
    rescue Errno::ECHILD
      child.reaped = true
      raise CredentialError
    end

    def stop_owned_process(child)
      return if child.reaped
      begin
        Process.kill('TERM', child.pid)
      rescue Errno::ESRCH
        # It exited without being reaped; poll below still owns that wait.
      end
      deadline = monotonic + 0.25
      sleep 0.01 until poll(child) || monotonic >= deadline
      return if child.reaped
      begin
        Process.kill('KILL', child.pid)
      rescue Errno::ESRCH
        # Reap an already-exited owned child below.
      end
      _, child.status = Process.waitpid2(child.pid)
      child.reaped = true
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
        raise CredentialError.new(:references)
      end
      key_id, issuer, pem = refs.map { |ref| reader.read(ref) }
      raise CredentialError.new(:invalid_value) if [key_id, issuer, pem].any? { |value| !value.is_a?(String) || value.strip.empty? }
      key_id, issuer = key_id.strip, issuer.strip
      # These enter JWT claims directly. Reject a miswired PEM/value before it
      # can become part of the bearer token. UUID syntax imposes no version rule.
      unless key_id.match?(/\A[A-Z0-9]{10}\z/) && issuer.match?(/\A[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\z/)
        raise CredentialError.new(:invalid_value)
      end
      begin
        key = OpenSSL::PKey.read(pem)
      rescue OpenSSL::PKey::PKeyError, ArgumentError
        raise CredentialError.new(:invalid_key), cause: nil
      end
      unless key.is_a?(OpenSSL::PKey::EC) && key.private? && key.group.curve_name == 'prime256v1'
        raise CredentialError.new(:invalid_key)
      end
      [key_id, issuer, key]
    rescue CredentialError => error
      raise CredentialError.new(error.reason), cause: nil
    rescue StandardError
      raise CredentialError.new, cause: nil
    end

    def self.valid_reference?(reference)
      return false unless reference.is_a?(String) && reference.start_with?('op://')
      return false if reference.match?(/[\r\n\0]/)
      parts = reference.delete_prefix('op://').split('/', -1)
      parts.length >= 3 && parts.all? { |part| !part.strip.empty? }
    end
  end
end
