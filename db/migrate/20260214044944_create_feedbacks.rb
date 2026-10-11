class CreateFeedbacks < ActiveRecord::Migration[7.1]
  def change
    create_table :feedbacks do |t|
      t.string :name, null: false
      t.string :email, null: false
      t.string :feedback_type, null: false
      t.text :content, null: false
      t.boolean :contact_permission, default: false, null: false

      t.timestamps
    end
  end
end
