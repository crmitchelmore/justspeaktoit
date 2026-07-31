#!/usr/bin/env ruby

require "base64"
require "json"
require "net/http"
require "openssl"
require "optparse"
require "uri"

options = {
  api_base: "https://api.appstoreconnect.apple.com",
  capabilities: [],
}

OptionParser.new do |parser|
  parser.on("--bundle-id IDENTIFIER") { |value| options[:bundle_id] = value }
  parser.on("--bundle-name NAME") { |value| options[:bundle_name] = value }
  parser.on("--capability TYPE") { |value| options[:capabilities] << value }
  parser.on("--certificate-serial SERIAL") { |value| options[:certificate_serial] = value }
  parser.on("--profile-name NAME") { |value| options[:profile_name] = value }
  parser.on("--output PATH") { |value| options[:output] = value }
end.parse!

required_options = %i[bundle_id certificate_serial profile_name output]
missing_options = required_options.reject { |key| options[key] && !options[key].empty? }
abort("Missing required options: #{missing_options.join(', ')}") unless missing_options.empty?

key_id = ENV.fetch("APP_STORE_CONNECT_KEY_ID")
issuer_id = ENV.fetch("APP_STORE_CONNECT_ISSUER_ID")
key_path = ENV.fetch("APP_STORE_CONNECT_KEY_PATH")
private_key = OpenSSL::PKey::EC.new(File.read(key_path))

def base64url(value)
  Base64.urlsafe_encode64(value, padding: false)
end

header = base64url(JSON.generate(alg: "ES256", kid: key_id, typ: "JWT"))
issued_at = Time.now.to_i
payload = base64url(JSON.generate(iss: issuer_id, iat: issued_at, exp: issued_at + 1_200, aud: "appstoreconnect-v1"))
unsigned_token = "#{header}.#{payload}"
der_signature = private_key.dsa_sign_asn1(OpenSSL::Digest::SHA256.digest(unsigned_token))
sequence = OpenSSL::ASN1.decode(der_signature)
raw_signature = sequence.value.map { |integer| integer.value.to_s(2).rjust(32, "\0") }.join
token = "#{unsigned_token}.#{base64url(raw_signature)}"

def request(api_base:, token:, method:, path:, body: nil)
  uri = URI.join(api_base, path)
  request = method.new(uri)
  request["Authorization"] = "Bearer #{token}"
  request["Content-Type"] = "application/json"
  request.body = JSON.generate(body) if body
  response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) { |http| http.request(request) }
  return response if response.is_a?(Net::HTTPSuccess)

  abort("App Store Connect API #{request.method} #{uri.path} failed (#{response.code}): #{response.body}")
end

def fetch_collection(api_base:, token:, path:)
  response = request(api_base: api_base, token: token, method: Net::HTTP::Get, path: path)
  JSON.parse(response.body).fetch("data")
end

escaped_bundle_id = URI.encode_www_form_component(options[:bundle_id])
bundle_ids = fetch_collection(
  api_base: options[:api_base],
  token: token,
  path: "/v1/bundleIds?filter%5Bidentifier%5D=#{escaped_bundle_id}"
)
abort("Multiple registered bundle IDs found for #{options[:bundle_id]}") if bundle_ids.length > 1

bundle = bundle_ids.first
unless bundle
  bundle_name = options[:bundle_name] || options[:bundle_id]
  create_body = {
    data: {
      type: "bundleIds",
      attributes: {
        identifier: options[:bundle_id],
        name: bundle_name,
        platform: "IOS",
      },
    },
  }
  response = request(
    api_base: options[:api_base],
    token: token,
    method: Net::HTTP::Post,
    path: "/v1/bundleIds",
    body: create_body
  )
  bundle = JSON.parse(response.body).fetch("data")
  puts "Registered bundle ID #{options[:bundle_id]}"
else
  puts "Reusing bundle ID #{options[:bundle_id]}"
end
bundle_resource_id = bundle.fetch("id")

unless options[:capabilities].empty?
  capabilities = fetch_collection(
    api_base: options[:api_base],
    token: token,
    path: "/v1/bundleIds/#{bundle_resource_id}/bundleIdCapabilities"
  )
  enabled_capabilities = capabilities.map { |capability| capability.dig("attributes", "capabilityType") }.compact

  options[:capabilities].uniq.each do |capability_type|
    if enabled_capabilities.include?(capability_type)
      puts "Reusing #{capability_type} capability for #{options[:bundle_id]}"
      next
    end

    create_body = {
      data: {
        type: "bundleIdCapabilities",
        attributes: {
          capabilityType: capability_type,
        },
        relationships: {
          bundleId: {
            data: { type: "bundleIds", id: bundle_resource_id },
          },
        },
      },
    }
    request(
      api_base: options[:api_base],
      token: token,
      method: Net::HTTP::Post,
      path: "/v1/bundleIdCapabilities",
      body: create_body
    )
    puts "Enabled #{capability_type} capability for #{options[:bundle_id]}"
  end
end

serial = options[:certificate_serial].delete(":").upcase.sub(/^0+/, "")
certificates = fetch_collection(
  api_base: options[:api_base],
  token: token,
  path: "/v1/certificates?filter%5BcertificateType%5D=DISTRIBUTION,IOS_DISTRIBUTION&limit=200"
)
certificate = certificates.find do |candidate|
  candidate_serial = candidate.dig("attributes", "serialNumber").to_s.delete(":").upcase.sub(/^0+/, "")
  candidate_serial == serial
end
abort("No Apple distribution certificate matched serial #{options[:certificate_serial]}") unless certificate

profile_name = "#{options[:profile_name]} #{serial[-8, 8]}"
escaped_profile_name = URI.encode_www_form_component(profile_name)
profiles = fetch_collection(
  api_base: options[:api_base],
  token: token,
  path: "/v1/profiles?filter%5Bname%5D=#{escaped_profile_name}&limit=200"
)

profile = profiles.find { |candidate| candidate.dig("attributes", "profileState") == "ACTIVE" }
unless profile
  create_body = {
    data: {
      type: "profiles",
      attributes: {
        name: profile_name,
        profileType: "IOS_APP_STORE",
      },
      relationships: {
        bundleId: {
          data: { type: "bundleIds", id: bundle_resource_id },
        },
        certificates: {
          data: [{ type: "certificates", id: certificate.fetch("id") }],
        },
      },
    },
  }
  response = request(
    api_base: options[:api_base],
    token: token,
    method: Net::HTTP::Post,
    path: "/v1/profiles",
    body: create_body
  )
  profile = JSON.parse(response.body).fetch("data")
  puts "Created provisioning profile #{profile_name}"
else
  puts "Reusing provisioning profile #{profile_name}"
end

content = profile.dig("attributes", "profileContent")
unless content
  response = request(
    api_base: options[:api_base],
    token: token,
    method: Net::HTTP::Get,
    path: "/v1/profiles/#{profile.fetch('id')}"
  )
  content = JSON.parse(response.body).dig("data", "attributes", "profileContent")
end
abort("Apple returned a profile without profileContent") unless content

File.binwrite(options[:output], Base64.decode64(content))
puts "Wrote provisioning profile to #{options[:output]}"
