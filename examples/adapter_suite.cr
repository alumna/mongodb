require "./support"
require "alumna/testing/adapter_suite"

# Alumna's adapter compliance suite. The factory runs inside every example,
# so it must drop the collection and return a fresh adapter.
# Ids are ObjectId hex, so expect_incremental_ids is false.
# Mixed $sort follows BSON order, so mixed_sort is :bson.
# The schema is strict: false because the suite writes every field below.
#
#   crystal spec examples/adapter_suite.cr

Alumna::Testing::AdapterSuite.run(
  "Alumna::MongoAdapter",
  expect_incremental_ids: false,
  mixed_sort: :bson,
) do
  begin
    Examples.client[Examples::DB]["suite"].drop
  rescue Mongo::Error
  end

  schema = Alumna::Schema.new(strict: false)
    .str("role").str("name").str("grade").str("status")
    .int("age").float("rating").bool("active").time("created")
    .hash("user") { |user| user.str("name"); user.int("age") }
    .array("tags", of: :str)
    .int("score").float("price").int("order_index").str("category").bool("is_published").bytes("blob")
    .str("title", required: false).str("sequence", required: false)
    .str("first_name", required: false).str("last_name", required: false)
    .int("view_count", required: false).any("metadata", nullable: true, required: false)

  Alumna::MongoAdapter.new(Examples.client, Examples::DB, "suite", schema)
end
