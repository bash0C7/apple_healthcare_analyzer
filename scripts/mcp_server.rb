# frozen_string_literal: true
# MCP stdio サーバー — db/health.db へのアドホッククエリ用
# .claude/settings.json の mcpServers セクションで設定。
# 直接起動: bundle exec ruby scripts/mcp_server.rb

require 'json'
require 'sqlite3'

DB_PATH   = 'db/health.db'.freeze
SAFE_STMT = /\A\s*SELECT\s/i.freeze

TOOLS = [
  {
    'name'        => 'query_health',
    'description' => <<~DESC.strip,
      db/health.db に対してSELECTクエリを実行。
      テーブル:
        records(date TEXT, metric TEXT, value REAL, unit TEXT) — 日次集計データ、UNIQUE(metric, date)
        daily_summary(date PK, step_count, active_energy, body_mass, body_fat, heart_rate, resting_hr, hrv, respiratory_rate, vo2max, sleep_hours, asleep_hours, body_battery INTEGER, updated_at)
        meta(key PK, value) — ベースライン・ロード日時など
    DESC
    'inputSchema' => {
      'type'       => 'object',
      'properties' => { 'sql' => { 'type' => 'string', 'description' => 'SQL SELECT文' } },
      'required'   => ['sql'],
    },
  },
  {
    'name'        => 'get_db_info',
    'description' => 'DBのメタ情報（ベースライン・最終ロード日時・レコード数）を返す',
    'inputSchema' => { 'type' => 'object', 'properties' => {} },
  },
].freeze

def open_db
  return nil unless File.exist?(DB_PATH)
  db = SQLite3::Database.new(DB_PATH, readonly: true)
  db.results_as_hash = true
  db.busy_timeout = 5000
  db
end

def respond(id, result)
  $stdout.puts JSON.generate({ 'jsonrpc' => '2.0', 'id' => id, 'result' => result })
  $stdout.flush
end

def error_response(id, code, message)
  $stdout.puts JSON.generate({ 'jsonrpc' => '2.0', 'id' => id, 'error' => { 'code' => code, 'message' => message } })
  $stdout.flush
end

def handle_tool_call(id, name, args, db)
  if db.nil?
    return error_response(id, -32_000, "DB が見つかりません: #{DB_PATH}。load_db.rb を実行してください。")
  end

  case name
  when 'query_health'
    sql = args['sql'].to_s.strip
    return error_response(id, -32_600, 'SELECT文のみ実行できます') unless SAFE_STMT.match?(sql)
    rows = db.execute(sql).first(2000)
    respond(id, { 'content' => [{ 'type' => 'text', 'text' => JSON.generate(rows) }] })
  when 'get_db_info'
    meta   = db.execute('SELECT key, value FROM meta ORDER BY key')
               .each_with_object({}) { |r, h| h[r['key']] = r['value'] }
    counts = db.execute('SELECT count(*) AS n FROM records').first&.fetch('n', 0)
    meta['total_records'] = counts
    respond(id, { 'content' => [{ 'type' => 'text', 'text' => JSON.generate(meta) }] })
  else
    error_response(id, -32_601, "不明なツール: #{name}")
  end
rescue SQLite3::Exception => e
  error_response(id, -32_000, "SQL エラー: #{e.message}")
end

db = open_db

$stdin.each_line do |line|
  line = line.strip
  next if line.empty?

  req    = JSON.parse(line)
  id     = req['id']
  method = req['method']
  params = req['params'] || {}

  case method
  when 'initialize'
    respond(id, {
      'protocolVersion' => '2024-11-05',
      'capabilities'    => { 'tools' => {} },
      'serverInfo'      => { 'name' => 'health-db', 'version' => '1.0.0' },
    })
  when 'initialized'
    next  # notification、レスポンス不要
  when 'tools/list'
    respond(id, { 'tools' => TOOLS })
  when 'tools/call'
    handle_tool_call(id, params['name'], params['arguments'] || {}, db)
  when 'ping'
    respond(id, {}) if id
  else
    error_response(id, -32_601, "不明なメソッド: #{method}") if id
  end
rescue JSON::ParserError => e
  $stderr.puts "JSON解析エラー: #{e.message}"
rescue => e
  $stderr.puts "エラー (#{method}): #{e.message}"
  $stderr.puts e.backtrace.first(3).join("\n")
end
