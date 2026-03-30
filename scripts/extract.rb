# frozen_string_literal: true
# Usage: bundle exec ruby scripts/extract.rb <xml> [from_yyyymmdd to_yyyymmdd [grain]]
# grain: full | daily | weekly | monthly  (default: full)

require 'ox'
require 'csv'
require 'date'
require 'time'
require 'fileutils'

TARGETS = {
  'HKQuantityTypeIdentifierStepCount'          => 'StepCount',
  'HKQuantityTypeIdentifierBodyMass'           => 'BodyMass',
  'HKQuantityTypeIdentifierHeartRate'          => 'HeartRate',
  'HKQuantityTypeIdentifierRestingHeartRate'   => 'RestingHeartRate',
  'HKQuantityTypeIdentifierActiveEnergyBurned' => 'ActiveEnergyBurned',
  'HKQuantityTypeIdentifierVO2Max'             => 'VO2Max',
  'HKQuantityTypeIdentifierBodyFatPercentage'  => 'BodyFatPercentage',
  'HKCategoryTypeIdentifierSleepAnalysis'      => 'SleepAnalysis',
}.freeze

AGGREGATION = {
  'StepCount'          => :sum,
  'BodyMass'           => :mean,
  'HeartRate'          => :mean,
  'RestingHeartRate'   => :mean,
  'ActiveEnergyBurned' => :sum,
  'VO2Max'             => :mean,
  'BodyFatPercentage'  => :mean,
  'SleepAnalysis'      => :sleep,
}.freeze

CSV_HEADERS = %w[creationDate startDate endDate value unit sourceName].freeze
OUTPUT_DIR  = 'output'.freeze
VALID_GRAINS = %w[full daily weekly monthly].freeze

def parse_args(argv)
  xml_path = argv[0] || abort('Usage: ruby scripts/extract.rb <xml> [from to [grain]]')
  abort("File not found: #{xml_path}") unless File.exist?(xml_path)

  from_date = argv[1] ? Date.strptime(argv[1], '%Y%m%d') : nil
  to_date   = argv[2] ? Date.strptime(argv[2], '%Y%m%d') : nil
  grain     = argv[3] || 'full'

  abort("grain must be: #{VALID_GRAINS.join('|')}") unless VALID_GRAINS.include?(grain)
  abort('Specify both from and to, or neither') if from_date.nil? != to_date.nil?

  [xml_path, from_date, to_date, grain]
end

def build_writers
  FileUtils.mkdir_p(OUTPUT_DIR)
  TARGETS.each_with_object({}) do |(_, metric), writers|
    path = File.join(OUTPUT_DIR, "#{metric}.csv")
    csv  = CSV.open(path, 'w', encoding: 'UTF-8')
    csv << CSV_HEADERS
    writers[metric] = csv
  end
end

def close_writers(writers)
  writers.each_value(&:close)
end

xml_path, from_date, to_date, grain = parse_args(ARGV)
writers = build_writers

$stderr.puts "Starting extraction: #{xml_path}"
$stderr.puts "Period: #{from_date || 'all'} - #{to_date || 'all'}, grain: #{grain}"

close_writers(writers)
$stderr.puts 'Done (SAX handler not yet implemented)'
