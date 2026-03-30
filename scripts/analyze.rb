# frozen_string_literal: true
# Usage: bundle exec ruby scripts/analyze.rb [days=90]
#        bundle exec ruby scripts/analyze.rb YYYYMMDD YYYYMMDD
# Outputs JSON to stdout. Progress/errors to stderr.

require 'csv'
require 'date'
require 'json'
require 'time'

OUTPUT_DIR = 'output'.freeze

def parse_args(argv)
  if argv.length == 2
    from = Date.strptime(argv[0], '%Y%m%d')
    to   = Date.strptime(argv[1], '%Y%m%d')
  else
    days = (argv[0] || 90).to_i
    to   = Date.today
    from = to - days + 1
  end
  [from, to]
end

def load_csv(metric)
  path = File.join(OUTPUT_DIR, "#{metric}.csv")
  unless File.exist?(path)
    $stderr.puts "WARN: #{path} not found, skipping"
    return []
  end
  CSV.read(path, headers: true)
rescue => e
  $stderr.puts "WARN: failed to read #{path}: #{e.message}"
  []
end

def parse_date(str)
  return nil if str.nil? || str.empty?
  Date.parse(str)
rescue ArgumentError
  nil
end

# Aggregate sum-type metrics (StepCount, ActiveEnergyBurned) by startDate day
def aggregate_sum(metric, from, to)
  rows = load_csv(metric)
  daily = Hash.new(0.0)
  rows.each do |row|
    d = parse_date(row['startDate'])
    next unless d && d >= from && d <= to
    daily[d] += row['value'].to_f
  end
  daily
end

# Aggregate mean-type metrics (BodyMass, HeartRate, RestingHeartRate, VO2Max, BodyFatPercentage)
# Returns hash of date => last value in day (for body measurements) or mean (for HR)
def aggregate_last(metric, from, to)
  rows = load_csv(metric)
  daily = {}
  rows.each do |row|
    d = parse_date(row['startDate'])
    next unless d && d >= from && d <= to
    v = row['value'].to_f
    next if v <= 0 || v > 1_000_000
    daily[d] = v
  end
  daily
end

def aggregate_mean(metric, from, to)
  rows = load_csv(metric)
  sums   = Hash.new(0.0)
  counts = Hash.new(0)
  rows.each do |row|
    d = parse_date(row['startDate'])
    next unless d && d >= from && d <= to
    v = row['value'].to_f
    next if v <= 0
    sums[d]   += v
    counts[d] += 1
  end
  sums.each_with_object({}) { |(d, s), h| h[d] = s / counts[d] }
end

# Sleep: sum (endDate - startDate) in hours, keyed by endDate day
def aggregate_sleep(from, to)
  rows = load_csv('SleepAnalysis')
  daily = Hash.new(0.0)
  rows.each do |row|
    d = parse_date(row['endDate'])
    next unless d && d >= from && d <= to
    start_t = Time.parse(row['startDate']) rescue next
    end_t   = Time.parse(row['endDate'])   rescue next
    hours = (end_t - start_t) / 3600.0
    daily[d] += hours if hours > 0 && hours < 24
  end
  daily
end

# Compute baseline RHR (10th percentile over full dataset)
def baseline_rhr_p10
  rows = load_csv('RestingHeartRate')
  values = rows.filter_map { |r| v = r['value'].to_f; v > 0 ? v : nil }
  return 55.0 if values.empty?
  values.sort[values.length / 10]
end

def body_battery(sleep_h, rhr, active_kcal, baseline_rhr)
  scores = []
  if sleep_h
    scores << [sleep_h / 7.5 * 40, 0, 40].sort[1]
  end
  if rhr && baseline_rhr
    scores << [[40 - [rhr - baseline_rhr, 0].max * 2.5, 0].max, 40].min
  end
  if active_kcal
    scores << [active_kcal / 600.0 * 20, 0, 20].sort[1]
  end
  return nil if scores.empty?
  # Scale proportionally if components are missing
  present = scores.length
  total   = 3
  (scores.sum * total.to_f / present).round
end

def mean_of(arr)
  valid = arr.compact
  return nil if valid.empty?
  (valid.sum / valid.length.to_f).round(2)
end

def recent_7d_mean(daily_hash, to)
  vals = (0..6).filter_map { |i| daily_hash[to - i] }
  mean_of(vals)
end

from, to = parse_args(ARGV)
$stderr.puts "Analyzing #{from} to #{to}..."

baseline = baseline_rhr_p10

steps   = aggregate_sum('StepCount',          from, to)
energy  = aggregate_sum('ActiveEnergyBurned', from, to)
sleep   = aggregate_sleep(from, to)
rhr     = aggregate_mean('RestingHeartRate',  from, to)
hr      = aggregate_mean('HeartRate',         from, to)
mass    = aggregate_last('BodyMass',          from, to)
fat     = aggregate_last('BodyFatPercentage', from, to)
vo2     = aggregate_last('VO2Max',            from, to)

# Fix BodyFatPercentage: convert 0-1 fraction to percentage if needed
fat = fat.transform_values { |v| v < 1.0 ? (v * 100).round(2) : v.round(2) } unless fat.empty?

all_dates = (from..to).to_a

daily = all_dates.map do |d|
  bb = body_battery(sleep[d], rhr[d], energy[d], baseline)
  {
    'date'          => d.to_s,
    'step_count'    => steps[d]&.round(0),
    'body_mass'     => mass[d]&.round(2),
    'resting_hr'    => rhr[d]&.round(1),
    'active_energy' => energy[d]&.round(1),
    'sleep_hours'   => sleep[d]&.round(2),
    'body_fat'      => fat[d],
    'vo2max'        => vo2[d]&.round(1),
    'body_battery'  => bb,
  }
end

# Summary stats
step_vals   = steps.values
energy_vals = energy.values
sleep_vals  = sleep.values.select { |v| v > 0 }
rhr_vals    = rhr.values
mass_vals   = mass.values

summary = {
  'step_count'         => { 'mean' => mean_of(step_vals), 'max' => step_vals.max&.round(0), 'min' => step_vals.min&.round(0), 'recent_7d_mean' => recent_7d_mean(steps, to) },
  'body_mass'          => { 'mean' => mean_of(mass_vals), 'latest' => mass[to] || mass.max_by { |d, _| d }&.last&.round(2) },
  'resting_heart_rate' => { 'mean' => mean_of(rhr_vals),  'min' => rhr_vals.min&.round(1), 'latest' => rhr[to] || rhr.max_by { |d, _| d }&.last&.round(1) },
  'active_energy'      => { 'mean' => mean_of(energy_vals), 'recent_7d_mean' => recent_7d_mean(energy, to) },
  'sleep_hours'        => { 'mean' => mean_of(sleep_vals), 'recent_7d_mean' => recent_7d_mean(sleep, to) },
  'body_fat'           => { 'latest' => fat.max_by { |d, _| d }&.last },
  'vo2max'             => { 'latest' => vo2.max_by { |d, _| d }&.last&.round(1) },
}

result = {
  'generated_at' => Date.today.to_s,
  'period'       => { 'from' => from.to_s, 'to' => to.to_s, 'days' => (to - from + 1).to_i },
  'baseline'     => { 'resting_hr_p10' => baseline.round(1) },
  'summary'      => summary,
  'daily'        => daily,
}

puts JSON.pretty_generate(result)
