class CreateCommandMappings < ActiveRecord::Migration[7.1]
  def change
    create_table :command_mappings do |t|
      t.references :script, null: false, foreign_key: true
      t.text :prompt
      t.text :mapping_file
      t.text :sandbox_debug_log
      t.text :debug_execution_result

      t.timestamps
    end
  end
end
