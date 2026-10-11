class AddInitialPromptAndPublishStatusToScripts < ActiveRecord::Migration[7.1]
  def change
    add_column :scripts, :initial_prompt, :text
    add_column :scripts, :publish_status, :string
  end
end
