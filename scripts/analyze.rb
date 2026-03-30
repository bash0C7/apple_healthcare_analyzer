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

# Sleep: sum (endDate - startDate) in hours keyed by endDate day.
# Returns [sleep_hours_hash, asleep_hours_hash].
# sleep_hours includes all categories; asleep_hours includes only Asleep* values.
ASLEEP_PATTERN = /Asleep/.freeze

def aggregate_sleep(from, to)
  rows = load_csv('SleepAnalysis')
  sleep_daily  = Hash.new(0.0)
  asleep_daily = Hash.new(0.0)
  rows.each do |row|
    d = parse_date(row['endDate'])
    next unless d && d >= from && d <= to
    start_t = Time.parse(row['startDate']) rescue next
    end_t   = Time.parse(row['endDate'])   rescue next
    hours = (end_t - start_t) / 3600.0
    next unless hours > 0 && hours < 24
    val = row['value'].to_s
    sleep_daily[d]  += hours
    asleep_daily[d] += hours if ASLEEP_PATTERN.match?(val)
  end
  [sleep_daily, asleep_daily]
end

# Compute baseline RHR (10th percentile over full dataset)
def baseline_rhr_p10
  rows = load_csv('RestingHeartRate')
  values = rows.filter_map { |r| v = r['value'].to_f; v > 0 ? v : nil }
  return 55.0 if values.empty?
  values.sort[values.length / 10]
end

# Compute mean HRV over all available data (global baseline)
def baseline_hrv_mean
  rows = load_csv('HRV')
  values = rows.filter_map { |r| v = r['value'].to_f; v > 0 ? v : nil }
  return nil if values.empty?
  (values.sum / values.length.to_f).round(2)
end

def body_battery(rhr, hrv, resp_rate, baseline_rhr, baseline_hrv)
  components = []

  if hrv && baseline_hrv && baseline_hrv > 0
    components << { score: [[hrv / baseline_hrv * 55, 0].max, 55].min, weight: 55 }
  end

  if rhr && baseline_rhr
    components << { score: [[30 - [rhr - baseline_rhr, 0].max * 1.875, 0].max, 30].min, weight: 30 }
  end

  if resp_rate
    dev = (resp_rate - 14.0).abs
    components << { score: [[15 - dev * 2.25, 0].max, 15].min, weight: 15 }
  end

  return nil if components.empty?

  total_weight = components.sum { |c| c[:weight] }
  raw_score    = components.sum { |c| c[:score] }
  (raw_score * 100.0 / total_weight).round
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

baseline_rhr = baseline_rhr_p10
baseline_hrv = baseline_hrv_mean

steps   = aggregate_sum('StepCount',          from, to)
energy  = aggregate_sum('ActiveEnergyBurned', from, to)
sleep, asleep = aggregate_sleep(from, to)
rhr     = aggregate_mean('RestingHeartRate',  from, to)
hrv     = aggregate_mean('HRV',              from, to)
resp    = aggregate_mean('RespiratoryRate',  from, to)
mass    = aggregate_last('BodyMass',          from, to)
fat     = aggregate_last('BodyFatPercentage', from, to)
vo2     = aggregate_last('VO2Max',            from, to)

# Fix BodyFatPercentage: convert 0-1 fraction to percentage if needed
fat = fat.transform_values { |v| v < 1.0 ? (v * 100).round(2) : v.round(2) } unless fat.empty?

all_dates = (from..to).to_a

daily = all_dates.map do |d|
  bb = body_battery(rhr[d], hrv[d], resp[d], baseline_rhr, baseline_hrv)
  {
    'date'             => d.to_s,
    'step_count'       => steps[d]&.round(0),
    'body_mass'        => mass[d]&.round(2),
    'resting_hr'       => rhr[d]&.round(1),
    'hrv'              => hrv[d]&.round(1),
    'active_energy'    => energy[d]&.round(1),
    'sleep_hours'      => sleep[d]&.round(2),
    'asleep_hours'     => asleep[d]&.round(2),
    'respiratory_rate' => resp[d]&.round(1),
    'body_fat'         => fat[d],
    'vo2max'           => vo2[d]&.round(1),
    'body_battery'     => bb,
  }
end

# Summary stats
step_vals   = steps.values
energy_vals = energy.values
sleep_vals  = sleep.values.select { |v| v > 0 }
asleep_vals = asleep.values.select { |v| v > 0 }
rhr_vals    = rhr.values
hrv_vals    = hrv.values
resp_vals   = resp.values
mass_vals   = mass.values

summary = {
  'step_count'         => { 'mean' => mean_of(step_vals), 'max' => step_vals.max&.round(0), 'min' => step_vals.min&.round(0), 'recent_7d_mean' => recent_7d_mean(steps, to) },
  'body_mass'          => { 'mean' => mean_of(mass_vals), 'latest' => mass[to] || mass.max_by { |d, _| d }&.last&.round(2) },
  'resting_heart_rate' => { 'mean' => mean_of(rhr_vals),  'min' => rhr_vals.min&.round(1), 'latest' => rhr[to] || rhr.max_by { |d, _| d }&.last&.round(1) },
  'active_energy'      => { 'mean' => mean_of(energy_vals), 'recent_7d_mean' => recent_7d_mean(energy, to) },
  'sleep_hours'        => { 'mean' => mean_of(sleep_vals), 'recent_7d_mean' => recent_7d_mean(sleep, to) },
  'asleep_hours'       => { 'mean' => mean_of(asleep_vals), 'recent_7d_mean' => recent_7d_mean(asleep, to) },
  'body_fat'           => { 'latest' => fat.max_by { |d, _| d }&.last },
  'vo2max'             => { 'latest' => vo2.max_by { |d, _| d }&.last&.round(1) },
  'hrv'                => { 'mean' => mean_of(hrv_vals), 'recent_7d_mean' => recent_7d_mean(hrv, to) },
  'respiratory_rate'   => { 'mean' => mean_of(resp_vals), 'recent_7d_mean' => recent_7d_mean(resp, to) },
}

result = {
  'generated_at' => Date.today.to_s,
  'period'       => { 'from' => from.to_s, 'to' => to.to_s, 'days' => (to - from + 1).to_i },
  'baseline'     => { 'resting_hr_p10' => baseline_rhr.round(1), 'hrv_mean' => baseline_hrv },
  'summary'      => summary,
  'daily'        => daily,
}

puts JSON.pretty_generate(result)
