require "./spec_helper"

Alumna::Testing::AdapterSuite.run("Alumna::MongoAdapter", expect_incremental_ids: false, mixed_sort: :bson) do
  drop_collection("adapter_test")

  schema = Alumna::Schema.new(strict: false)
    .str("role").str("name").str("grade").str("status")
    .int("age").float("rating").bool("active").time("created")
    .hash("user") { |u| u.str("name"); u.int("age") }
    .array("tags", of: :str)
    .int("score").float("price").int("order_index").str("category").bool("is_published").bytes("blob")
    .str("title", required: false).str("sequence", required: false)
    .str("first_name", required: false).str("last_name", required: false)
    .int("view_count", required: false).any("metadata", nullable: true, required: false)

  Alumna::MongoAdapter.new(SHARED_CLIENT, TEST_DB, "adapter_test", schema)
end
