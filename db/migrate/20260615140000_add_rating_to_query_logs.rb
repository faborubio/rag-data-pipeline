class AddRatingToQueryLogs < ActiveRecord::Migration[8.1]
  # User feedback on an answer: 1 = 👍, -1 = 👎, null = no vote yet.
  def change
    add_column :query_logs, :rating, :integer
  end
end
