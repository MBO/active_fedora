module ActiveFedora
  # = Active Fedora Persistence
  module Persistence
    extend ActiveSupport::Concern

    #Saves a Base object, and any dirty datastreams, then updates 
    #the Solr index for this object.
    def save(*)
      # If it's a new object, set the conformsTo relationship for Fedora CMA
      if new_record?
        result = create
        update_index if create_needs_index?
      else
        result = update
        update_index if update_needs_index?
      end
      return result
    end

    def save!(*)
      save
    end

    # This can be overriden to assert a different model
    # It's normally called once in the lifecycle, by #create#
    def assert_content_model
      add_relationship(:has_model, self.class.to_class_uri)
    end

    def update_attributes(properties)
      self.attributes=properties
      save
    end

    # Refreshes the object's info from Fedora
    # Note: Currently just registers any new datastreams that have appeared in fedora
    def refresh
#      inner_object.load_attributes_from_fedora
    end

    def dependent_objects
      # Loop over all the inbound associations (has_many reflections)
      results = {}
      reflections.each_pair do |name, reflection|
        if reflection.macro == :has_many
          results[reflection.options[:property]] = send(name)
        end
      end
      results.merge (inbound_relationships(:object) )
    end

    #Deletes a Base object, also deletes the info indexed in Solr, and 
    #the underlying inner_object.  If this object is held in any relationships (ie inbound relationships
    #outside of this object it will remove it from those items rels-ext as well
    def delete
      dependent_objects.each_pair do |predicate, objects|
        objects.each do |obj|
          if obj.respond_to?(:remove_relationship)
            obj.remove_relationship(predicate,self)
            obj.save
          end 
        end
      end
      
      #Fedora::Repository.instance.delete(@inner_object)
      pid = self.pid ## cache so it's still available after delete
      begin
        @inner_object.delete
      rescue RestClient::ResourceNotFound =>e
        raise ObjectNotFoundError, "Unable to find #{pid} in the repository"
      end
      if ENABLE_SOLR_UPDATES
        solr = ActiveFedora::SolrService.instance.conn
        solr.delete_by_id(pid) 
        solr.commit
      end
    end

    def destroy
      delete
    end

    module ClassMethods
      # Creates an object (or multiple objects) and saves it to the repository, if validations pass.
      # The resulting object is returned whether the object was saved successfully to the repository or not.
      #
      # The +attributes+ parameter can be either be a Hash or an Array of Hashes.  These Hashes describe the
      # attributes on the objects that are to be created.
      #
      # ==== Examples
      #   # Create a single new object
      #   User.create(:first_name => 'Jamie')
      #
      #   # Create an Array of new objects
      #   User.create([{ :first_name => 'Jamie' }, { :first_name => 'Jeremy' }])
      #
      #   # Create a single object and pass it into a block to set other attributes.
      #   User.create(:first_name => 'Jamie') do |u|
      #     u.is_admin = false
      #   end
      #
      #   # Creating an Array of new objects using a block, where the block is executed for each object:
      #   User.create([{ :first_name => 'Jamie' }, { :first_name => 'Jeremy' }]) do |u|
      #     u.is_admin = false
      #   end
      def create(attributes = nil, &block)
        if attributes.is_a?(Array)
          attributes.collect { |attr| create(attr, &block) }
        else
          object = new(attributes)
          yield(object) if block_given?
          object.save
          object
        end
      end
    end

  protected

    # Determines whether a create operation cause a solr index of this object.
    # Override this if you need different behavior
    def create_needs_index?
      ENABLE_SOLR_UPDATES
    end

    # Determines whether an update operation cause a solr index of this object.
    # Override this if you need different behavior
    def update_needs_index?
      ENABLE_SOLR_UPDATES
    end

  private
    
    # Deals with preparing new object to be saved to Fedora, then pushes it and its datastreams into Fedora. 
    def create
      assign_pid
      assert_content_model
      persist
    end

    # replace the unsaved digital object with a saved digital object
    def assign_pid
      @inner_object = @inner_object.save 
    end
    
    # Pushes the object and all of its new or dirty datastreams into Fedora
    def update
      persist
    end

    def persist
      result = @inner_object.save

      ### Rubydora re-inits the datastreams after a save, so ensure our copy stays in synch
      @inner_object.datastreams.each do |dsid, ds|
        datastreams[dsid] = ds
        ds.model = self if ds.kind_of? RelsExtDatastream
      end 
      refresh
      return !!result
    end
  end
end
