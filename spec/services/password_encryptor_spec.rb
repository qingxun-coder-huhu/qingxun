# frozen_string_literal: true

require 'spec_helper'
require 'securerandom'
require 'base64'
require 'openssl'

# 独立测试 PasswordEncryptor（不依赖 Settings）
class PasswordEncryptor
  ALGORITHM = 'AES-256-GCM'
  IV_LENGTH = 12
  AUTH_TAG_LENGTH = 16
  KEY_LENGTH = 32

  class EncryptionError < StandardError; end
  class DecryptionError < StandardError; end
  class KeyNotConfiguredError < StandardError; end

  attr_reader :key

  def initialize(key:)
    @key = key
    validate_key!
  end

  def encrypt(plain_password)
    raise EncryptionError, "密码不能为空" if plain_password.nil? || plain_password.empty?

    begin
      iv = SecureRandom.random_bytes(IV_LENGTH)
      cipher = OpenSSL::Cipher.new(ALGORITHM)
      cipher.encrypt
      cipher.key = @key
      cipher.iv = iv
      encrypted = cipher.update(plain_password.encode('UTF-8')) + cipher.final
      auth_tag = cipher.auth_tag
      combined = iv + encrypted + auth_tag
      Base64.strict_encode64(combined)
    rescue OpenSSL::Cipher::CipherError => e
      raise EncryptionError, "加密失败: #{e.message}"
    rescue StandardError => e
      raise EncryptionError, "加密失败: #{e.message}"
    end
  end

  def decrypt(encrypted_password)
    raise DecryptionError, "加密数据不能为空" if encrypted_password.nil? || encrypted_password.empty?

    begin
      combined = Base64.strict_decode64(encrypted_password)
      min_length = IV_LENGTH + 1 + AUTH_TAG_LENGTH
      raise DecryptionError, "加密数据格式无效" if combined.length < min_length

      iv = combined[0, IV_LENGTH]
      auth_tag = combined[-AUTH_TAG_LENGTH, AUTH_TAG_LENGTH]
      ciphertext = combined[IV_LENGTH..(-AUTH_TAG_LENGTH - 1)]

      cipher = OpenSSL::Cipher.new(ALGORITHM)
      cipher.decrypt
      cipher.key = @key
      cipher.iv = iv
      cipher.auth_tag = auth_tag
      decrypted = cipher.update(ciphertext) + cipher.final
      decrypted.force_encoding('UTF-8')
    rescue OpenSSL::Cipher::CipherError => e
      raise DecryptionError, "解密失败: 密钥错误或数据损坏"
    rescue ArgumentError => e
      raise DecryptionError, "解密失败: #{e.message}"
    rescue StandardError => e
      raise DecryptionError, "解密失败: #{e.message}"
    end
  end

  def aes_encrypted?(encrypted_value)
    return false if encrypted_value.nil? || encrypted_value.empty?
    return false if encrypted_value.start_with?('$2')
    begin
      decoded = Base64.strict_decode64(encrypted_value)
      decoded.length >= IV_LENGTH + 1 + AUTH_TAG_LENGTH
    rescue ArgumentError
      false
    end
  end

  def bcrypt_encrypted?(encrypted_value)
    return false if encrypted_value.nil? || encrypted_value.empty?
    encrypted_value.match?(/\A\$2[aby]\$\d+\$/)
  end

  private

  def validate_key!
    raise KeyNotConfiguredError, "加密密钥未配置" if @key.nil?
    raise KeyNotConfiguredError, "加密密钥长度无效，需要 #{KEY_LENGTH} 字节" if @key.bytesize != KEY_LENGTH
  end
end

RSpec.describe PasswordEncryptor do
  let(:valid_key) { SecureRandom.bytes(32) }
  let(:encryptor) { described_class.new(key: valid_key) }

  describe '#initialize' do
    it 'accepts a valid 32-byte key' do
      expect { described_class.new(key: valid_key) }.not_to raise_error
    end

    it 'rejects nil key' do
      expect { described_class.new(key: nil) }.to raise_error(PasswordEncryptor::KeyNotConfiguredError)
    end

    it 'rejects short key' do
      short_key = SecureRandom.bytes(16)
      expect { described_class.new(key: short_key) }.to raise_error(PasswordEncryptor::KeyNotConfiguredError)
    end
  end

  describe '#encrypt' do
    it 'encrypts a plain password' do
      encrypted = encryptor.encrypt('my_secret_password')
      expect(encrypted).to be_a(String)
      expect(encrypted).not_to eq('my_secret_password')
    end

    it 'returns Base64 encoded string' do
      encrypted = encryptor.encrypt('password123')
      expect { Base64.strict_decode64(encrypted) }.not_to raise_error
    end

    it 'produces different ciphertext for same password (random IV)' do
      encrypted1 = encryptor.encrypt('same_password')
      encrypted2 = encryptor.encrypt('same_password')
      expect(encrypted1).not_to eq(encrypted2)
    end

    it 'raises error for nil password' do
      expect { encryptor.encrypt(nil) }.to raise_error(PasswordEncryptor::EncryptionError, /不能为空/)
    end

    it 'raises error for empty password' do
      expect { encryptor.encrypt('') }.to raise_error(PasswordEncryptor::EncryptionError, /不能为空/)
    end

    it 'handles special characters' do
      special_password = '!@#$%^&*()_+-=[]{}|;:,.<>?/~`中文字密码'
      encrypted = encryptor.encrypt(special_password)
      decrypted = encryptor.decrypt(encrypted)
      expect(decrypted).to eq(special_password)
    end
  end

  describe '#decrypt' do
    it 'decrypts an encrypted password' do
      plain = 'my_secret_password'
      encrypted = encryptor.encrypt(plain)
      decrypted = encryptor.decrypt(encrypted)
      expect(decrypted).to eq(plain)
    end

    it 'raises error for nil encrypted value' do
      expect { encryptor.decrypt(nil) }.to raise_error(PasswordEncryptor::DecryptionError, /不能为空/)
    end

    it 'raises error for empty encrypted value' do
      expect { encryptor.decrypt('') }.to raise_error(PasswordEncryptor::DecryptionError, /不能为空/)
    end

    it 'raises error for invalid Base64' do
      expect { encryptor.decrypt('not_valid_base64!!!') }.to raise_error(PasswordEncryptor::DecryptionError)
    end

    it 'raises error for wrong key' do
      encrypted = encryptor.encrypt('password')
      wrong_key = SecureRandom.bytes(32)
      wrong_encryptor = described_class.new(key: wrong_key)
      expect { wrong_encryptor.decrypt(encrypted) }.to raise_error(PasswordEncryptor::DecryptionError, /密钥错误/)
    end

    it 'raises error for tampered ciphertext' do
      encrypted = encryptor.encrypt('password')
      decoded = Base64.strict_decode64(encrypted)
      tampered = decoded.chars.map(&:ord)
      tampered[20] ^= 0xFF
      tampered_encrypted = Base64.strict_encode64(tampered.map(&:chr).join)
      expect { encryptor.decrypt(tampered_encrypted) }.to raise_error(PasswordEncryptor::DecryptionError)
    end
  end

  describe '#aes_encrypted?' do
    it 'returns true for AES encrypted value' do
      encrypted = encryptor.encrypt('password')
      expect(encryptor.aes_encrypted?(encrypted)).to be true
    end

    it 'returns false for BCrypt format' do
      bcrypt_hash = '$2a$10$abcdefghijklmnopqrstuvwxyz123456'
      expect(encryptor.aes_encrypted?(bcrypt_hash)).to be false
    end

    it 'returns false for nil' do
      expect(encryptor.aes_encrypted?(nil)).to be false
    end

    it 'returns false for empty string' do
      expect(encryptor.aes_encrypted?('')).to be false
    end
  end

  describe '#bcrypt_encrypted?' do
    it 'returns true for BCrypt format' do
      bcrypt_hash = '$2a$10$abcdefghijklmnopqrstuvwxyz1234567890ABCDEF'
      expect(encryptor.bcrypt_encrypted?(bcrypt_hash)).to be true
    end

    it 'returns true for $2b format' do
      bcrypt_hash = '$2b$10$abcdefghijklmnopqrstuvwxyz1234567890ABCDEF'
      expect(encryptor.bcrypt_encrypted?(bcrypt_hash)).to be true
    end

    it 'returns false for AES encrypted value' do
      encrypted = encryptor.encrypt('password')
      expect(encryptor.bcrypt_encrypted?(encrypted)).to be false
    end

    it 'returns false for nil' do
      expect(encryptor.bcrypt_encrypted?(nil)).to be false
    end
  end

  describe 'round-trip encryption' do
    it 'encrypts and decrypts correctly' do
      passwords = [
        'simple',
        'with spaces',
        'with!@#$%^special',
        '中文密码测试',
        'a' * 1000
      ]

      passwords.each do |password|
        encrypted = encryptor.encrypt(password)
        decrypted = encryptor.decrypt(encrypted)
        expect(decrypted).to eq(password)
      end
    end
  end
end
