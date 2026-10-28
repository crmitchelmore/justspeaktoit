#!/usr/bin/env ruby
# frozen_string_literal: true
require_relative 'release-apple'
require 'open3'
client = AppleRelease::Client.new
output, status = Open3.capture2('git','for-each-ref','--format=%(refname:short)','refs/tags/alpha-build-*','refs/tags/stable-candidate-*')
abort 'Cannot read release ledger' unless status.success?
require_relative 'apple-reconciliation'
failures=[]
manifests=output.lines.map(&:strip).map do |tag|
  data, result = Open3.capture2('git','for-each-ref','--format=%(contents)',"refs/tags/#{tag}")
  abort "Cannot read release manifest: #{tag}" unless result.success?
  JSON.parse(data)
end
tag = ENV['RECONCILE_TAG'].to_s.strip
AppleRelease.reconciliation_manifests(manifests, tag: tag.empty? ? nil : tag).each do |manifest|
  tag = manifest.fetch('tag')
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
