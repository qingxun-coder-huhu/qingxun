# frozen_string_literal: true

class AddActivationFieldsToUsers < ActiveRecord::Migration[7.1]
  def change
    add_column :users, :activation_token, :string
    add_column :users, :activated_at, :datetime
  end
end
