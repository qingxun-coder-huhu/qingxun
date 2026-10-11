# frozen_string_literal: true

# 设备连接密码的加密密钥。
#
# 开源版的目标是"开箱即用"：不强制使用者额外配置一套加密密钥。这里从
# SECRET_KEY_BASE（Rails 每个部署唯一）派生出 ActiveRecord::Encryption 所需的
# 三把密钥，于是设备密码以密文入库、随部署密钥不同而不同。
#
# 如果需要显式控制密钥，可在环境变量中设置：
#   ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY / _DETERMINISTIC_KEY / _KEY_DERIVATION_SALT
keys = Rails.application.key_generator

Rails.application.config.active_record.encryption.primary_key =
  ENV['ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY'].presence ||
  keys.generate_key('qingxun_ar_encryption_primary', 32)

Rails.application.config.active_record.encryption.deterministic_key =
  ENV['ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY'].presence ||
  keys.generate_key('qingxun_ar_encryption_deterministic', 32)

Rails.application.config.active_record.encryption.key_derivation_salt =
  ENV['ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT'].presence ||
  keys.generate_key('qingxun_ar_encryption_salt', 32)
