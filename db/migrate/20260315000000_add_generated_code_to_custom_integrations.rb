# frozen_string_literal: true

class AddGeneratedCodeToCustomIntegrations < ActiveRecord::Migration[7.1]
  def change
    unless column_exists?(:custom_integrations, :generated_code)
      add_column :custom_integrations, :generated_code, :text
    end
  end
end
