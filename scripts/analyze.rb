# frozen_string_literal: true
# Usage: bundle exec ruby scripts/analyze.rb [days=90]
#        bundle exec ruby scripts/analyze.rb YYYYMMDD YYYYMMDD
# Outputs JSON to stdout. Progress/errors to stderr.

require 'date'
require 'json'
require 'sqlite3'

DB_PATH = 'db/health.db'.freeze

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

def open_db
  abort("DB が見つかりません: #{DB_PATH}\n実行してください: bundle exec ruby scripts/load_db.rb") unless File.exist?(DB_PATH)
  db = SQLite3::Database.new(DB_PATH, readonly: true)
  db.results_as_hash = true
  db.busy_timeout = 5000
  db
end

def load_baselines(db)
  rows = db.execute("SELECT key, value FROM meta WHERE key IN ('baseline_rhr_p10', 'baseline_hrv_mean')")
  h = rows.each_with_object({}) { |r, acc| acc[r['key']] = r['value'].to_f }
  [h['baseline_rhr_p10'] || 55.0, h['baseline_hrv_mean']]
end

def load_daily_rows(db, from, to)
  db.execute(<<~SQL, [from.to_s, to.to_s])
    SELECT date, step_count, body_mass, resting_hr, hrv, active_energy,
           sleep_hours, asleep_hours, respiratory_rate, body_fat, vo2max, body_battery
    FROM daily_summary
    WHERE date BETWEEN ? AND ?
    ORDER BY date ASC
  SQL
end

def mean_of(vals)
  valid = vals.compact
  return nil if valid.empty?
  (valid.sum / valid.length.to_f).round(2)
end

def recent_7d_mean(db, column, to)
  rows = db.execute(<<~SQL, [to.to_s])
    SELECT #{column} FROM (
      SELECT #{column} FROM daily_summary
      WHERE date <= ? AND #{column} IS NOT NULL
      ORDER BY date DESC LIMIT 7
    )
  SQL
  mean_of(rows.map { |r| r[column] })
end

def latest_non_null(db, column, to)
  db.execute(<<~SQL, [to.to_s]).first&.fetch(column)
    SELECT #{column} FROM daily_summary
    WHERE date <= ? AND #{column} IS NOT NULL
    ORDER BY date DESC LIMIT 1
  SQL
end

from, to = parse_args(ARGV)
$stderr.puts "Analyzing #{from} to #{to}..."

db = open_db
baseline_rhr, baseline_hrv = load_baselines(db)
daily_rows = load_daily_rows(db, from, to)

row_by_date = daily_rows.each_with_object({}) { |r, h| h[r['date']] = r }
all_dates   = (from..to).to_a

daily = all_dates.map do |d|
  r = row_by_date[d.to_s] || {}
  {
    'date'             => d.to_s,
    'step_count'       => r['step_count']&.round(0),
    'body_mass'        => r['body_mass']&.round(2),
    'resting_hr'       => r['resting_hr']&.round(1),
    'hrv'              => r['hrv']&.round(1),
    'active_energy'    => r['active_energy']&.round(1),
    'sleep_hours'      => r['sleep_hours']&.round(2),
    'asleep_hours'     => r['asleep_hours']&.round(2),
    'respiratory_rate' => r['respiratory_rate']&.round(1),
    'body_fat'         => r['body_fat'],
    'vo2max'           => r['vo2max']&.round(1),
    'body_battery'     => r['body_battery'],
  }
end

step_vals   = daily_rows.map { |r| r['step_count'] }.compact
energy_vals = daily_rows.map { |r| r['active_energy'] }.compact
sleep_vals  = daily_rows.map { |r| r['sleep_hours'] }.compact.select { |v| v > 0 }
asleep_vals = daily_rows.map { |r| r['asleep_hours'] }.compact.select { |v| v > 0 }
rhr_vals    = daily_rows.map { |r| r['resting_hr'] }.compact
hrv_vals    = daily_rows.map { |r| r['hrv'] }.compact
resp_vals   = daily_rows.map { |r| r['respiratory_rate'] }.compact
mass_vals   = daily_rows.map { |r| r['body_mass'] }.compact

summary = {
  'step_count'         => { 'mean' => mean_of(step_vals),   'max' => step_vals.max&.round(0),  'min' => step_vals.min&.round(0),  'recent_7d_mean' => recent_7d_mean(db, 'step_count', to) },
  'body_mass'          => { 'mean' => mean_of(mass_vals),   'latest' => latest_non_null(db, 'body_mass', to)&.round(2) },
  'resting_heart_rate' => { 'mean' => mean_of(rhr_vals),    'min' => rhr_vals.min&.round(1),   'latest' => latest_non_null(db, 'resting_hr', to)&.round(1) },
  'active_energy'      => { 'mean' => mean_of(energy_vals), 'recent_7d_mean' => recent_7d_mean(db, 'active_energy', to) },
  'sleep_hours'        => { 'mean' => mean_of(sleep_vals),  'recent_7d_mean' => recent_7d_mean(db, 'sleep_hours', to) },
  'asleep_hours'       => { 'mean' => mean_of(asleep_vals), 'recent_7d_mean' => recent_7d_mean(db, 'asleep_hours', to) },
  'body_fat'           => { 'latest' => latest_non_null(db, 'body_fat', to) },
  'vo2max'             => { 'latest' => latest_non_null(db, 'vo2max', to)&.round(1) },
  'hrv'                => { 'mean' => mean_of(hrv_vals),    'recent_7d_mean' => recent_7d_mean(db, 'hrv', to) },
  'respiratory_rate'   => { 'mean' => mean_of(resp_vals),   'recent_7d_mean' => recent_7d_mean(db, 'respiratory_rate', to) },
}

result = {
  'generated_at' => Date.today.to_s,
  'period'       => { 'from' => from.to_s, 'to' => to.to_s, 'days' => (to - from + 1).to_i },
  'baseline'     => { 'resting_hr_p10' => baseline_rhr.round(1), 'hrv_mean' => baseline_hrv },
  'summary'      => summary,
  'daily'        => daily,
}

puts JSON.pretty_generate(result)
