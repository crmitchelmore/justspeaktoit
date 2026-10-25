require 'minitest/autorun'
require 'rbconfig'
require_relative '../release-apple'

class AppleReleaseCredentialsTest < Minitest::Test
  class FakeOp
    attr_reader :calls
    def initialize(values = {}, error: nil)
      @values, @error, @calls = values, error, []
    end
    def read(reference)
      @calls << reference
      raise @error if @error
      @values.fetch(reference)
    end
  end

  def setup
    @pem = OpenSSL::PKey::EC.generate('prime256v1').to_pem
    @env = {'APP_STORE_CONNECT_CREDENTIAL_SOURCE' => '1password'}
    @refs = %w[op://Release/Apple/key-id op://Release/Apple/issuer-id op://Release/Apple/private-key]
    AppleRelease::VaultCredentials::REFERENCES.zip(@refs).each { |name, reference| @env[name] = reference }
    @values = @refs.zip(['SYNTHETIC1', 'synthetic-issuer', @pem]).to_h
  end

  def test_selected_vault_source_signs_existing_jwt_entirely_in_memory
    reader = FakeOp.new(@values)
    File.stub(:read, ->(*) { flunk 'Vault source must not read a credential file' }) do
      client = AppleRelease::Client.new(env: @env, op_reader: reader)
      token = IOSProfileBootstrap.jwt_token(
        key_id: client.instance_variable_get(:@key_id), issuer_id: client.instance_variable_get(:@issuer),
        private_key: client.instance_variable_get(:@key))
      header, payload, signature = token.split('.')
      assert_equal 'SYNTHETIC1', JSON.parse(Base64.urlsafe_decode64(header)).fetch('kid')
      assert_equal 'synthetic-issuer', JSON.parse(Base64.urlsafe_decode64(payload)).fetch('iss')
      assert_equal 64, Base64.urlsafe_decode64(signature).bytesize
    end
    assert_equal @refs, reader.calls
  end

  def test_missing_any_reference_fails_before_op_or_legacy_fallback
    (AppleRelease::VaultCredentials::REFERENCES + [:all]).each do |missing|
      env = @env.merge('APP_STORE_CONNECT_KEY_ID' => 'legacy', 'APP_STORE_CONNECT_ISSUER_ID' => 'legacy',
        'APP_STORE_CONNECT_KEY_PATH' => '/never/read/legacy.p8')
      missing == :all ? AppleRelease::VaultCredentials::REFERENCES.each { |name| env.delete(name) } : env.delete(missing)
      reader = FakeOp.new(@values)
      File.stub(:read, ->(*) { flunk 'Missing vault configuration must not fall back' }) do
        assert_raises(AppleRelease::CredentialError) { AppleRelease::Client.new(env: env, op_reader: reader) }
      end
      assert_empty reader.calls
    end
  end

  def test_failed_read_is_redacted_and_never_falls_back
    reader = FakeOp.new(error: RuntimeError.new("sensitive #{@refs.first} #{@pem}"))
    File.stub(:read, ->(*) { flunk 'Failed vault read must not fall back' }) do
      error = assert_raises(AppleRelease::CredentialError) { AppleRelease::Client.new(env: @env, op_reader: reader) }
      refute_includes error.full_message, 'sensitive'
      refute_includes error.full_message, 'op://'
      refute_includes error.full_message, 'PRIVATE KEY'
      assert_nil error.cause
    end
  end

  def test_non_p256_public_and_malformed_keys_are_rejected_without_echoing_values
    public_der = OpenSSL::ASN1::Sequence.new([
      OpenSSL::ASN1::Sequence.new([OpenSSL::ASN1::ObjectId.new('id-ecPublicKey'), OpenSSL::ASN1::ObjectId.new('prime256v1')]),
      OpenSSL::ASN1::BitString.new(OpenSSL::PKey::EC.new(@pem).public_key.to_bn.to_s(2))
    ]).to_der
    [OpenSSL::PKey::EC.generate('secp384r1').to_pem,
      public_der, 'invalid-secret-pem'].each do |pem|
      reader = FakeOp.new(@values.merge(@refs.last => pem))
      error = assert_raises(AppleRelease::CredentialError) { AppleRelease::Client.new(env: @env, op_reader: reader) }
      refute_includes error.full_message.b, pem.b
      assert_nil error.cause
    end
  end

  def test_blank_secret_and_invalid_reference_fail_closed
    [@env.merge(AppleRelease::VaultCredentials::REFERENCES.first => 'not-an-op-reference'),
      @env.merge(AppleRelease::VaultCredentials::REFERENCES.first => "op://vault/item/field\n")].each do |env|
      reader = FakeOp.new(@values)
      assert_raises(AppleRelease::CredentialError) { AppleRelease::Client.new(env: env, op_reader: reader) }
      assert_empty reader.calls
    end
    reader = FakeOp.new(@values.merge(@refs.first => ' '))
    assert_raises(AppleRelease::CredentialError) { AppleRelease::Client.new(env: @env, op_reader: reader) }
  end

  def test_default_source_preserves_existing_ci_environment_and_file_contract
    env = {'APP_STORE_CONNECT_KEY_ID' => 'CIKEY', 'APP_STORE_CONNECT_ISSUER_ID' => 'CIISSUER',
      'APP_STORE_CONNECT_KEY_PATH' => '/synthetic-ci-key.p8'}
    reader = FakeOp.new
    File.stub(:read, ->(path) { assert_equal '/synthetic-ci-key.p8', path; @pem }) do
      client = AppleRelease::Client.new(env: env, op_reader: reader)
      assert_equal 'CIKEY', client.instance_variable_get(:@key_id)
      assert_equal 'CIISSUER', client.instance_variable_get(:@issuer)
    end
    assert_empty reader.calls
  end

  def test_unknown_source_fails_without_reading_any_credential
    reader = FakeOp.new
    File.stub(:read, ->(*) { flunk 'Unknown source must not read files' }) do
      error = assert_raises(AppleRelease::CredentialError) do
        AppleRelease::Client.new(env: @env.merge('APP_STORE_CONNECT_CREDENTIAL_SOURCE' => 'untrusted-value'), op_reader: reader)
      end
      refute_includes error.message, 'untrusted-value'
    end
    assert_empty reader.calls
  end

  def test_fake_op_captures_secret_without_output_and_uses_literal_argv
    calls = []
    spawn = ->(*argv, &block) do
      calls << argv
      Open3.popen3(RbConfig.ruby, '-e', 'STDOUT.write("synthetic-value")', &block)
    end
    reader = AppleRelease::OpReader.new(spawn: spawn)
    reference = 'op://Vault/Item/field$(no-shell);literal'
    out, err = capture_io { assert_equal 'synthetic-value', reader.read(reference) }
    assert_empty out
    assert_empty err
    assert_equal [['op', 'read', '--no-newline', reference]], calls
  end

  def test_fake_op_failure_redacts_both_streams_and_exception_cause
    spawn = ->(*, &block) do
      Open3.popen3(RbConfig.ruby, '-e', 'STDOUT.write("secret-output"); STDERR.write("secret-error op://vault/item/field"); exit 2', &block)
    end
    out, err = capture_io do
      error = assert_raises(AppleRelease::CredentialError) { AppleRelease::OpReader.new(spawn: spawn).read(@refs.first) }
      refute_includes error.full_message, 'secret-'
      refute_includes error.full_message, 'op://'
      assert_nil error.cause
    end
    assert_empty out
    assert_empty err
  end

  def test_fake_op_timeout_terminates_and_reaps_only_its_owned_process
    owned_pid = nil
    unrelated = Process.spawn(RbConfig.ruby, '-e', 'sleep 30', out: File::NULL, err: File::NULL)
    spawn = ->(*, &block) do
      Open3.popen3(RbConfig.ruby, '-e', 'trap("TERM") {}; STDERR.write("secret-timeout"); sleep 30') do |*handles|
        owned_pid = handles.last.pid
        block.call(*handles)
      end
    end
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    out, err = capture_io do
      error = assert_raises(AppleRelease::CredentialError) do
        AppleRelease::OpReader.new(spawn: spawn, timeout: 0.2).read(@refs.first)
      end
      refute_includes error.full_message, 'secret-timeout'
      refute_includes error.full_message, 'op://'
      assert_nil error.cause
    end
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 3
    assert_raises(Errno::ESRCH) { Process.kill(0, owned_pid) }
    assert_raises(Errno::ECHILD) { Process.waitpid(owned_pid, Process::WNOHANG) }
    assert_equal 1, Process.kill(0, unrelated)
    assert_empty out
    assert_empty err
  ensure
    Process.kill('TERM', unrelated) if unrelated
    Process.waitpid(unrelated) if unrelated
  end
end
