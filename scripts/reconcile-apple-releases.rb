#!/usr/bin/env ruby
# frozen_string_literal: true
require_relative 'release-apple'
require 'open3'
client = AppleRelease::Client.new
output, status = Open3.capture2('git','for-each-ref','--format=%(refname:short)','refs/tags/alpha-build-*','refs/tags/stable-candidate-*')
abort 'Cannot read release ledger' unless status.success?
failures=[]
output.lines.map(&:strip).each do |tag|
  data, result = Open3.capture2('git','for-each-ref','--format=%(contents)',"refs/tags/#{tag}")
  next unless result.success?
  manifest=JSON.parse(data)
  # Expired Alpha builds remain in the ledger but cannot be made installable.
  # Rebuild explicitly if the most recent Alpha approaches TestFlight's 90 days.
  if manifest['train'] == 'alpha' && Time.parse(manifest['createdAt']) < Time.now - 90*86_400
    next
  end
  %w[ios mac-store].each do |surface|
    begin
      delivery=AppleRelease::Delivery.new(client:client,manifest:manifest,surface:surface)
      delivery.distribute(wait_seconds:0) if delivery.build
      delivery.observe_publication if manifest['train'] == 'stable'
    rescue StandardError => error
      warn "#{tag} #{surface}: #{error.message}"
      failures << "#{tag} #{surface}"
    end
  end
end
abort "Apple reconciliation needs attention: #{failures.join(', ')}" unless failures.empty?
