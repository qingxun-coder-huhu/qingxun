# frozen_string_literal: true

class CreateCustomIntegrations < ActiveRecord::Migration[7.1]
  def change
    unless table_exists?(:custom_integrations)
      create_table :custom_integrations do |t|
        t.references :user, null: false, foreign_key: true
        t.jsonb :functions, default: []

        t.timestamps
      end
    end
  end
end
