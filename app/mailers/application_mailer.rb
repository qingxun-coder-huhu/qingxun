# frozen_string_literal: true

# 邮件控制器基类
#
# 所有邮件控制器应继承此类
class ApplicationMailer < ActionMailer::Base
  default from: ENV.fetch('MAIL_FROM_ADDRESS', 'noreply@qingxun.example.com')
  layout 'mailer'
end
