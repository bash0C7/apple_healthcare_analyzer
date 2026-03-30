# frozen_string_literal: true
# Usage: bundle exec ruby scripts/import_xml.rb <xml_path>
# Apple Health export.xml から全レコードを db/health.db の raw_records テーブルに取り込む。
# 初回のみ実行。DB が存在する場合は何もしない。
# 完全再構築: rm db/health.db && bundle exec ruby scripts/import_xml.rb <xml>

require 'ox'
require 'fileutils'
require 'sqlite3'

TARGETS = {
  'HKQuantityTypeIdentifierStepCount'                => 'StepCount',
  'HKQuantityTypeIdentifierBodyMass'                 => 'BodyMass',
  'HKQuantityTypeIdentifierHeartRate'                => 'HeartRate',
  'HKQuantityTypeIdentifierRestingHeartRate'         => 'RestingHeartRate',
  'HKQuantityTypeIdentifierActiveEnergyBurned'       => 'ActiveEnergyBurned',
  'HKQuantityTypeIdentifierVO2Max'                   => 'VO2Max',
  'HKQuantityTypeIdentifierBodyFatPercentage'        => 'BodyFatPercentage',
  'HKCategoryTypeIdentifierSleepAnalysis'            => 'SleepAnalysis',
  'HKQuantityTypeIdentifierHeartRateVariabilitySDNN' => 'HRV',
  'HKQuantityTypeIdentifierRespiratoryRate'          => 'RespiratoryRate',
}.freeze

DB_PATH    = 'db/health.db'.freeze
BATCH_SIZE = 500

SCHEMA_SQL = [
  <<~SQL,
    CREATE TABLE IF NOT EXISTS raw_records (
      id            INTEGER PRIMARY KEY,
      metric        TEXT NOT NULL,
      start_date    TEXT NOT NULL,
      end_date      TEXT NOT NULL,
      creation_date TEXT,
      value         TEXT NOT NULL,
      unit          TEXT,
      source        TEXT
    )
  SQL
  'CREATE INDEX IF NOT EXISTS idx_raw_metric       ON raw_records (metric)',
  'CREATE INDEX IF NOT EXISTS idx_raw_start        ON raw_records (start_date)',
  'CREATE INDEX IF NOT EXISTS idx_raw_metric_start ON raw_records (metric, start_date)',
].freeze

def open_db(path)
  FileUtils.mkdir_p(File.dirname(path))
  db = SQLite3::Database.new(path)
  db.execute('PRAGMA journal_mode=WAL')
  db.execute('PRAGMA synchronous=NORMAL')
  db.execute('PRAGMA cache_size=-65536')  # 64MBキャッシュ
  SCHEMA_SQL.each { |sql| db.execute(sql) }
  db
end

# SAXハンドラ: Record要素を検出してバッチでSQLiteに挿入
class XmlImporter < Ox::Sax
  def initialize(db)
    @db         = db
    @stmt       = db.prepare(<<~SQL)
      INSERT INTO raw_records (metric, start_date, end_date, creation_date, value, unit, source)
      VALUES (?, ?, ?, ?, ?, ?, ?)
    SQL
    @attrs      = nil
    @collecting = false
    @count      = 0
    @batch      = []
  end

  def start_element(name)
    @collecting = (name == :Record)
    @attrs      = {} if @collecting
  end

  def attr(name, value)
    @attrs[name] = value if @collecting
  end

  def end_element(name)
    process_record(@attrs) if name == :Record && @attrs
    @attrs      = nil
    @collecting = false
  end

  def flush
    return if @batch.empty?
    @db.transaction { @batch.each { |row| @stmt.execute(*row) } }
    @batch.clear
  end

  def close
    flush
    @stmt.close
  end

  attr_reader :count

  private

  def process_record(attrs)
    metric = TARGETS[attrs[:type]]
    return unless metric

    @count += 1
    $stderr.puts "  #{@count} 件処理済み..." if (@count % 100_000).zero?

    @batch << [
      metric,
      attrs[:startDate].to_s,
      attrs[:endDate].to_s,
      attrs[:creationDate].to_s,
      attrs[:value].to_s,
      attrs[:unit].to_s,
      attrs[:sourceName].to_s,
    ]

    flush if @batch.size >= BATCH_SIZE
  end
end

# ---- main ----

xml_path = ARGV[0] || abort('Usage: bundle exec ruby scripts/import_xml.rb <xml_path>')
abort("ファイルが見つかりません: #{xml_path}") unless File.exist?(xml_path)

if File.exist?(DB_PATH)
  $stderr.puts "#{DB_PATH} は既に存在します（スキップ）。"
  $stderr.puts "完全再構築: rm #{DB_PATH} && bundle exec ruby scripts/import_xml.rb #{xml_path}"
  exit 0
end

$stderr.puts "インポート開始: #{xml_path}"
$stderr.puts "対象メトリクス: #{TARGETS.values.join(', ')}"

db       = open_db(DB_PATH)
importer = XmlImporter.new(db)

File.open(xml_path, 'rb') { |f| Ox.sax_parse(importer, f) }
importer.close

total = importer.count
db.execute('INSERT INTO raw_records SELECT NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL WHERE 0') rescue nil # warm-up check
db.close

$stderr.puts "完了: #{total} 件 → #{DB_PATH}"
$stderr.puts "次のステップ: bundle exec ruby scripts/build_summary.rb"
