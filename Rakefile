# frozen_string_literal: true

TEST_DB = 'db/test_health.db'
SAMPLE_XML = 'data/sample.xml'

desc 'SAXパイプライン全体の回帰テスト（匿名化サンプル使用）'
task :test do
  abort 'data/export.xml が見つかりません' unless File.exist?('data/export.xml')

  puts '--- [1/4] 匿名化サンプル生成 ---'
  sh "bundle exec ruby scripts/gen_sample.rb data/export.xml"

  puts '--- [2/4] サンプルXMLをインポート ---'
  FileUtils.rm_f(TEST_DB)
  sh "HEALTH_DB_PATH=#{TEST_DB} bundle exec ruby scripts/import_xml.rb #{SAMPLE_XML}"

  puts '--- [3/4] daily_summary 構築 ---'
  sh "HEALTH_DB_PATH=#{TEST_DB} bundle exec ruby scripts/build_summary.rb"

  puts '--- [4/4] 結果検証 ---'
  require 'sqlite3'
  db = SQLite3::Database.new(TEST_DB)
  raw_count     = db.execute('SELECT COUNT(*) FROM raw_records').first.first
  summary_count = db.execute('SELECT COUNT(*) FROM daily_summary').first.first
  date_range    = db.execute('SELECT MIN(date), MAX(date) FROM daily_summary').first
  db.close
  FileUtils.rm_f(TEST_DB)

  abort "raw_records が 0 件" if raw_count.zero?
  abort "daily_summary が 0 件" if summary_count.zero?

  puts "raw_records: #{raw_count} 件"
  puts "daily_summary: #{summary_count} 件 (#{date_range[0]} 〜 #{date_range[1]})"
  puts 'OK'
end
