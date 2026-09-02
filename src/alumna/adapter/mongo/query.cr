class Alumna::MongoAdapter
  # Typed filters → one BSON document. Native $ne/$nin on arrays match MemoryAdapter (D22).
  module Query
    EMPTY = BSON.new

    def self.filter_bson(
      typed_filters : Hash(String, Array(Alumna::Query::TypedCondition)),
      schema : Schema,
    ) : BSON | ServiceError
      return EMPTY if typed_filters.empty?

      typed_filters.each_key do |field|
        unless known_field?(schema, field)
          return ServiceError.bad_request("Unknown query field: #{field}")
        end
      end

      BSON.build do |bson|
        typed_filters.each do |field, conditions|
          id_field = field == "id" || field == "_id"
          mongo_field = id_field ? "_id" : field
          if conditions.size == 1 && conditions[0].op.eq?
            write_operand(bson, mongo_field, conditions[0].value, id_field)
          else
            bson.document(mongo_field) do
              conditions.each do |cond|
                write_operand(bson, op_key(cond.op), cond.value, id_field)
              end
            end
          end
        end
      end
    end

    private def self.known_field?(schema : Schema, field : String) : Bool
      return true if field == "id" || field == "_id"
      !schema.find_field(field).nil?
    end

    private def self.op_key(op : Alumna::Query::Op) : String
      case op
      in .eq?  then "$eq"
      in .ne?  then "$ne"
      in .gt?  then "$gt"
      in .gte? then "$gte"
      in .lt?  then "$lt"
      in .lte? then "$lte"
      in .in?  then "$in"
      in .nin? then "$nin"
      end
    end

    # id/_id: valid 24-hex → ObjectId. Anything else stays as written, so $eq matches nothing.
    private def self.write_operand(builder : BSON::Builder, key : String, value : AnyData, id_field : Bool) : Nil
      if id_field
        case value
        when String
          if oid = Identity.parse?(value)
            builder[key] = oid
            return
          end
        when Array
          write_id_array(builder, key, value)
          return
        end
      end
      BsonWrite.write_field(builder, key, value)
    end

    private def self.write_id_array(builder : BSON::Builder, key : String, items : Array(AnyData)) : Nil
      builder.array(key) do
        items.each_with_index do |item, index|
          idx = index < 128 ? BSON::Builder::STATIC_INDICES.unsafe_fetch(index) : index.to_s
          if item.is_a?(String)
            if oid = Identity.parse?(item)
              builder[idx] = oid
              next
            end
          end
          BsonWrite.write_field(builder, idx, item)
        end
      end
    end
  end
end
