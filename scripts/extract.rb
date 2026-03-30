# frozen_string_literal: true
# Usage: bundle exec ruby scripts/extract.rb <xml> [from_yyyymmdd to_yyyymmdd [grain]]
# grain: full | daily | weekly | monthly  (default: full)

require 'ox'
require 'csv'
require 'date'
require 'time'
require 'fileutils'
require 'tmpdir'

TARGETS = {
  'HKQuantityTypeIdentifierStepCount'          => 'StepCount',
  'HKQuantityTypeIdentifierBodyMass'           => 'BodyMass',
  'HKQuantityTypeIdentifierHeartRate'          => 'HeartRate',
  'HKQuantityTypeIdentifierRestingHeartRate'   => 'RestingHeartRate',
  'HKQuantityTypeIdentifierActiveEnergyBurned' => 'ActiveEnergyBurned',
  'HKQuantityTypeIdentifierVO2Max'             => 'VO2Max',
  'HKQuantityTypeIdentifierBodyFatPercentage'        => 'BodyFatPercentage',
  'HKCategoryTypeIdentifierSleepAnalysis'            => 'SleepAnalysis',
  'HKQuantityTypeIdentifierHeartRateVariabilitySDNN' => 'HRV',
  'HKQuantityTypeIdentifierRespiratoryRate'          => 'RespiratoryRate',
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
  'HRV'                => :mean,
  'RespiratoryRate'    => :mean,
}.freeze

CSV_HEADERS  = %w[creationDate startDate endDate value unit sourceName].freeze
OUTPUT_DIR   = 'output'.freeze
VALID_GRAINS = %w[full daily weekly monthly].freeze
SESSION_ID   = "#{Time.now.strftime('%Y%m%d_%H%M%S')}_#{Process.pid}".freeze
TMP_DIR      = File.join(Dir.tmpdir, "health_extract_#{SESSION_ID}").freeze

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
  FileUtils.mkdir_p(TMP_DIR)
  TARGETS.each_with_object({}) do |(_, metric), writers|
    path = File.join(TMP_DIR, "#{metric}.csv")
    csv  = CSV.open(path, 'w', encoding: 'UTF-8')
    csv << CSV_HEADERS
    writers[metric] = csv
  end
end

def close_writers(writers)
  writers.each_value(&:close)
end

def flush_to_output
  FileUtils.mkdir_p(OUTPUT_DIR)
  TARGETS.each_value do |metric|
    src = File.join(TMP_DIR, "#{metric}.csv")
    dst = File.join(OUTPUT_DIR, "#{metric}.csv")
    FileUtils.mv(src, dst)
  end
  FileUtils.rmdir(TMP_DIR)
  $stderr.puts "Output written to #{OUTPUT_DIR}/ (session: #{SESSION_ID})"
end

class SaxHandler < Ox::Sax
  def initialize(writers, from_date, to_date, grain)
    @writers        = writers
    @from           = from_date
    @to             = to_date
    @grain          = grain
    @attrs          = nil
    @collecting     = false
    @count          = 0
    @buffers        = {}
  end

  def start_element(name)
    if name == :Record
      @attrs      = {}
      @collecting = true
    else
      @collecting = false
    end
  end

  def attr(name, value)
    @attrs[name] = value if @collecting
  end

  def end_element(name)
    if name == :Record && @attrs
      process_record(@attrs)
      @attrs      = nil
      @collecting = false
    else
      @collecting = false
    end
  end

  def flush
    @buffers.each do |metric, keyed|
      keyed.each { |key, buf| write_aggregated(@writers[metric], key, metric, buf) }
    end
  end

  private

  def process_record(attrs)
    metric = TARGETS[attrs[:type]]
    return unless metric

    @count += 1
    $stderr.puts "Processed #{@count} records..." if (@count % 100_000).zero?

    return unless in_range?(attrs[:startDate])

    @grain == 'full' ? write_full(@writers[metric], attrs) : accumulate(metric, attrs)
  end

  def in_range?(start_date_str)
    return true if @from.nil?
    date = Date.parse(start_date_str)
    date >= @from && date <= @to
  end

  def write_full(csv, attrs)
    csv << [attrs[:creationDate], attrs[:startDate], attrs[:endDate],
            attrs[:value], attrs[:unit], attrs[:sourceName]]
  end

  def grain_key(start_date_str)
    date = Date.parse(start_date_str)
    case @grain
    when 'daily'   then date.strftime('%Y-%m-%d')
    when 'weekly'  then date.strftime('%Y-W%V')
    when 'monthly' then date.strftime('%Y-%m')
    end
  end

  def accumulate(metric, attrs)
    key = grain_key(attrs[:startDate])
    buf = (@buffers[metric] ||= {})[key] ||=
            { sum: 0.0, count: 0, last_creation: nil, last_end: nil, unit: nil }

    case AGGREGATION[metric]
    when :sum
      buf[:sum] += attrs[:value].to_f
    when :mean
      buf[:sum]   += attrs[:value].to_f
      buf[:count] += 1
    when :sleep
      start_t     = Time.parse(attrs[:startDate])
      end_t       = Time.parse(attrs[:endDate])
      buf[:sum]  += (end_t - start_t) / 60.0
    end

    buf[:last_creation] = attrs[:creationDate]
    buf[:last_end]      = attrs[:endDate]
    buf[:unit]          = attrs[:unit]
  end

  def write_aggregated(csv, key, metric, buf)
    value = case AGGREGATION[metric]
            when :sum   then buf[:sum].round(4)
            when :mean  then (buf[:sum] / buf[:count]).round(4)
            when :sleep then buf[:sum].round(2)
            end
    unit = AGGREGATION[metric] == :sleep ? 'min' : buf[:unit]
    csv << [buf[:last_creation], key, buf[:last_end], value, unit, 'aggregated']
  end
end

xml_path, from_date, to_date, grain = parse_args(ARGV)
writers = build_writers

$stderr.puts "Starting extraction: #{xml_path}"
$stderr.puts "Period: #{from_date || 'all'} - #{to_date || 'all'}, grain: #{grain}"

handler = SaxHandler.new(writers, from_date, to_date, grain)

File.open(xml_path, 'rb') do |f|
  Ox.sax_parse(handler, f)
end

handler.flush unless grain == 'full'
close_writers(writers)
flush_to_output
$stderr.puts 'Extraction complete.'
