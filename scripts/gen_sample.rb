# frozen_string_literal: true
# Usage: bundle exec ruby scripts/gen_sample.rb export.xml

SAMPLE_TYPES = %w[
  HKQuantityTypeIdentifierStepCount
  HKQuantityTypeIdentifierBodyMass
  HKQuantityTypeIdentifierHeartRate
  HKQuantityTypeIdentifierRestingHeartRate
  HKQuantityTypeIdentifierActiveEnergyBurned
  HKQuantityTypeIdentifierVO2Max
  HKQuantityTypeIdentifierBodyFatPercentage
  HKCategoryTypeIdentifierSleepAnalysis
].freeze

RECORDS_PER_TYPE = 10

def collect_records(xml_path)
  counts  = Hash.new(0)
  records = []

  File.foreach(xml_path) do |line|
    next unless line.include?('<Record ')

    SAMPLE_TYPES.each do |type|
      if line.include?(%(type="#{type}")) && counts[type] < RECORDS_PER_TYPE
        rec = line.chomp.strip
        rec = rec.end_with?('/>') ? rec : rec.sub(/>$/, '/>')
        records << rec
        counts[type] += 1
        break
      end
    end

    break if SAMPLE_TYPES.all? { |t| counts[t] >= RECORDS_PER_TYPE }
  end

  warn_missing(counts)
  records
end

def warn_missing(counts)
  SAMPLE_TYPES.each do |type|
    n = counts[type]
    $stderr.puts "WARN: #{type} only #{n} records found" if n < RECORDS_PER_TYPE
  end
end

def write_sample_xml(records, output_path)
  File.open(output_path, 'w', encoding: 'UTF-8') do |f|
    f.puts '<?xml version="1.0" encoding="UTF-8"?>'
    f.puts '<HealthData locale="en_US">'
    records.each { |r| f.puts "  #{r.strip}" }
    f.puts '</HealthData>'
  end
end

xml_path    = ARGV[0] || abort('Usage: ruby scripts/gen_sample.rb <export.xml>')
output_path = 'data/sample.xml'

abort("File not found: #{xml_path}") unless File.exist?(xml_path)

$stderr.puts "Scanning #{xml_path}..."
records = collect_records(xml_path)
write_sample_xml(records, output_path)
$stderr.puts "Written #{records.size} records to #{output_path}"
