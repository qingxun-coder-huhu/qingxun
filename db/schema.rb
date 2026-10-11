# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[7.1].define(version: 2026_10_12_000003) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "plpgsql"

  create_table "command_mappings", force: :cascade do |t|
    t.bigint "script_id", null: false
    t.text "prompt"
    t.text "mapping_file"
    t.text "sandbox_debug_log"
    t.text "debug_execution_result"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["script_id"], name: "index_command_mappings_on_script_id"
  end

  create_table "custom_integrations", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.jsonb "functions", default: []
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.text "generated_code"
    t.jsonb "history", default: [], null: false
    t.index ["user_id"], name: "index_custom_integrations_on_user_id"
  end

  create_table "device_models", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "name", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index "user_id, lower((name)::text)", name: "index_device_models_on_user_and_lower_name", unique: true
    t.index ["user_id"], name: "index_device_models_on_user_id"
  end

  create_table "network_elements", id: :string, force: :cascade do |t|
    t.string "name", null: false
    t.text "description"
    t.bigint "user_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "device_model"
    t.boolean "active", default: true, null: false
    t.string "ip_address"
    t.integer "port"
    t.string "connection_type", default: "telnet", null: false
    t.string "username"
    t.text "password"
    t.string "enable_command"
    t.text "enable_password"
    t.text "root_password"
    t.string "ssh_key_path"
    t.index ["device_model"], name: "index_network_elements_on_device_model"
    t.index ["user_id", "name"], name: "index_network_elements_on_user_id_and_name", unique: true
    t.index ["user_id"], name: "index_network_elements_on_user_id"
  end

  create_table "script_versions", force: :cascade do |t|
    t.bigint "script_id", null: false
    t.bigint "user_id", null: false
    t.integer "revision", null: false
    t.string "name"
    t.text "description"
    t.text "code"
    t.text "initial_prompt"
    t.json "command_mapping", default: {}
    t.json "device_models", default: []
    t.json "branch_scenarios", default: []
    t.string "publish_status"
    t.string "source", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["script_id", "created_at"], name: "index_script_versions_on_script_id_and_created_at"
    t.index ["script_id", "revision"], name: "index_script_versions_on_script_id_and_revision", unique: true
  end

  create_table "scripts", force: :cascade do |t|
    t.string "name", null: false
    t.text "description", null: false
    t.text "code", null: false
    t.json "command_mapping", default: {}
    t.json "device_types", default: []
    t.json "tags", default: []
    t.string "version", default: "1.0.0", null: false
    t.boolean "public", default: false
    t.integer "usage_count", default: 0
    t.bigint "user_id", null: false
    t.bigint "parent_script_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.text "initial_prompt"
    t.string "publish_status"
    t.json "device_models"
    t.json "branch_scenarios", default: [], comment: "分支覆盖测试场景（名称/描述/命令映射/通过与否）"
    t.string "script_uid", null: false, comment: "脚本唯一标识（页面初始化时确定，类名后缀同此值）"
    t.integer "revision", default: 0, null: false
    t.index ["parent_script_id"], name: "index_scripts_on_parent_script_id"
    t.index ["public"], name: "index_scripts_on_public"
    t.index ["script_uid"], name: "index_scripts_on_script_uid", unique: true
    t.index ["user_id"], name: "index_scripts_on_user_id"
  end

  create_table "task_executions", force: :cascade do |t|
    t.bigint "task_id", null: false
    t.string "network_element_id", null: false
    t.bigint "script_id", null: false
    t.string "status", default: "pending", null: false
    t.text "logs"
    t.json "result", default: {}
    t.text "error_message"
    t.integer "duration_ms"
    t.datetime "started_at"
    t.datetime "finished_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "task_run_id"
    t.index ["network_element_id"], name: "index_task_executions_on_network_element_id"
    t.index ["script_id"], name: "index_task_executions_on_script_id"
    t.index ["task_id"], name: "index_task_executions_on_task_id"
    t.index ["task_run_id", "network_element_id", "script_id"], name: "index_task_executions_on_run_device_script", unique: true
    t.index ["task_run_id"], name: "index_task_executions_on_task_run_id"
  end

  create_table "task_network_elements", force: :cascade do |t|
    t.bigint "task_id", null: false
    t.string "network_element_id", null: false
    t.string "status", default: "pending", null: false
    t.integer "sequence", default: 0
    t.datetime "started_at"
    t.datetime "completed_at"
    t.float "duration"
    t.json "result", default: {}
    t.text "output"
    t.text "error_message"
    t.string "skip_reason"
    t.integer "retry_count", default: 0
    t.string "client_device_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["completed_at"], name: "index_task_network_elements_on_completed_at"
    t.index ["network_element_id"], name: "index_task_network_elements_on_network_element_id"
    t.index ["sequence"], name: "index_task_network_elements_on_sequence"
    t.index ["started_at"], name: "index_task_network_elements_on_started_at"
    t.index ["status"], name: "index_task_network_elements_on_status"
    t.index ["task_id"], name: "index_task_network_elements_on_task_id"
  end

  create_table "task_runs", force: :cascade do |t|
    t.bigint "task_id", null: false
    t.string "status", default: "pending", null: false
    t.integer "progress", default: 0, null: false
    t.jsonb "result", default: {}
    t.text "error_message"
    t.datetime "started_at"
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["task_id"], name: "index_task_runs_on_task_id"
  end

  create_table "task_scripts", force: :cascade do |t|
    t.bigint "task_id", null: false
    t.bigint "script_id", null: false
    t.integer "sequence", default: 0, null: false
    t.json "parameters", default: {}
    t.text "condition"
    t.string "expected_result", default: "success"
    t.string "status", default: "pending", null: false
    t.string "skip_reason"
    t.float "average_duration"
    t.integer "success_count", default: 0
    t.integer "failure_count", default: 0
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["condition"], name: "index_task_scripts_on_condition", where: "(condition IS NOT NULL)"
    t.index ["script_id"], name: "index_task_scripts_on_script_id"
    t.index ["status"], name: "index_task_scripts_on_status"
    t.index ["task_id", "script_id"], name: "idx_task_script_unique", unique: true
    t.index ["task_id", "sequence"], name: "idx_task_sequence"
    t.index ["task_id"], name: "index_task_scripts_on_task_id"
  end

  create_table "tasks", force: :cascade do |t|
    t.string "name", null: false
    t.text "description"
    t.string "status", default: "pending", null: false
    t.string "execution_mode", default: "cloud", null: false
    t.integer "progress", default: 0
    t.integer "device_count", default: 0
    t.integer "script_count", default: 0
    t.json "execution_params", default: {}
    t.json "result", default: {}
    t.datetime "started_at"
    t.datetime "completed_at"
    t.text "error_message"
    t.bigint "user_id", null: false
    t.string "client_task_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["completed_at"], name: "index_tasks_on_completed_at"
    t.index ["created_at"], name: "index_tasks_on_created_at"
    t.index ["execution_mode"], name: "index_tasks_on_execution_mode"
    t.index ["progress"], name: "index_tasks_on_progress"
    t.index ["started_at"], name: "index_tasks_on_started_at"
    t.index ["status"], name: "index_tasks_on_status"
    t.index ["user_id", "name"], name: "index_tasks_on_user_id_and_name", unique: true
    t.index ["user_id"], name: "index_tasks_on_user_id"
  end

  create_table "users", force: :cascade do |t|
    t.string "email"
    t.string "password_digest"
    t.string "wechat_openid"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "last_login_at", comment: "最后登录时间"
    t.string "last_login_ip", comment: "最后登录IP地址"
    t.boolean "activated", default: false, null: false, comment: "账户是否已激活"
    t.boolean "admin", default: false, null: false, comment: "是否为管理员"
    t.text "notes", comment: "用户备注信息"
    t.datetime "api_last_used_at"
    t.string "activation_token"
    t.datetime "activated_at"
    t.datetime "terms_accepted_at", comment: "同意服务条款的时间"
    t.string "terms_version", comment: "同意的服务条款版本"
    t.datetime "privacy_accepted_at", comment: "同意隐私政策的时间"
    t.string "privacy_version", comment: "同意的隐私政策版本"
    t.datetime "deactivated_at"
    t.string "reset_token"
    t.datetime "reset_sent_at"
    t.string "client_code_digest", comment: "识别码的 HMAC 摘要（不可逆，明文不落库）"
    t.datetime "code_generated_at", comment: "识别码生成/重置时间"
    t.string "wechat_id", comment: "客户微信号，用于售后沟通与人工找回"
    t.text "code_note", comment: "识别码找回的人工核验备注（举证与留痕）"
    t.string "registration_ip"
    t.index ["client_code_digest"], name: "index_users_on_client_code_digest", unique: true
    t.index ["deactivated_at"], name: "index_users_on_deactivated_at"
    t.index ["email"], name: "index_users_on_email", unique: true, where: "(deactivated_at IS NULL)"
    t.index ["privacy_accepted_at"], name: "index_users_on_privacy_accepted_at"
    t.index ["reset_sent_at"], name: "index_users_on_reset_sent_at"
    t.index ["reset_token"], name: "index_users_on_reset_token", unique: true
    t.index ["terms_accepted_at"], name: "index_users_on_terms_accepted_at"
    t.index ["wechat_openid"], name: "index_users_on_wechat_openid", unique: true, where: "(deactivated_at IS NULL)"
  end

  add_foreign_key "command_mappings", "scripts"
  add_foreign_key "custom_integrations", "users"
  add_foreign_key "device_models", "users", on_delete: :cascade
  add_foreign_key "network_elements", "users"
  add_foreign_key "script_versions", "scripts", on_delete: :cascade
  add_foreign_key "scripts", "scripts", column: "parent_script_id"
  add_foreign_key "scripts", "users"
  add_foreign_key "task_executions", "scripts"
  add_foreign_key "task_executions", "task_runs"
  add_foreign_key "task_executions", "tasks"
  add_foreign_key "task_network_elements", "tasks"
  add_foreign_key "task_runs", "tasks"
  add_foreign_key "task_scripts", "scripts"
  add_foreign_key "task_scripts", "tasks"
  add_foreign_key "tasks", "users"
end
