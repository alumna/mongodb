class Alumna::MongoAdapter
  # Sort, skip, limit, select. $select always keeps _id (D28). $limit is clamped only when max_limit is set (D20).
  module FindOptions
    def self.skip(query : Alumna::Query) : Int32?
      query.skip
    end

    def self.limit(query : Alumna::Query, max_limit : Int32?) : Int32?
      lim = query.limit
      return nil unless lim
      if max = max_limit
        lim > max ? max : lim
      else
        lim
      end
    end

    def self.sort_bson(query : Alumna::Query, schema : Schema) : BSON | ServiceError | Nil
      sort = query.sort
      return nil unless sort

      BSON.build do |bson|
        sort.each do |field, dir|
          unless known_field?(schema, field)
            return ServiceError.bad_request("Unknown sort field: #{field}")
          end
          mongo_field = field == "id" ? "_id" : field
          bson[mongo_field] = dir
        end
      end
    end

    def self.projection_bson(query : Alumna::Query, schema : Schema) : BSON | ServiceError | Nil
      fields = query.select
      return nil unless fields

      BSON.build do |bson|
        bson["_id"] = 1
        fields.each do |field|
          next if field == "id" || field == "_id"
          unless known_field?(schema, field)
            return ServiceError.bad_request("Invalid select field: #{field}")
          end
          bson[field] = 1
        end
      end
    end

    private def self.known_field?(schema : Schema, field : String) : Bool
      return true if field == "id" || field == "_id"
      !schema.find_field(field).nil?
    end
  end
end
