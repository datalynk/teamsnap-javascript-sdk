# A representation of a Collection+JSON collection
class Collection

  @fromData: (data) ->
    new Collection().deserialize(data)

  constructor: (data = {}) ->
    @href = data.href
    @links = new MetaList(data.links)
    @queries = new MetaList(data.queries)
    @commands = new MetaList(data.commands)
    @template = data.template or []
    @items = data.items if data.items

  # Deserialize the data from the server into this collection object
  deserialize: (data) ->
    data = data.collection if data.collection
    return unless data
    @href = data.href
    @links.deserialize data.links
    @queries.deserialize data.queries
    @commands.deserialize data.commands
    @template = data.template?.data or []
    if data.items?.length
      @items = data.items # Not Item objects, just the data for scoped to turn
    this


# Wraps a collection adding a request object scoped for a given user
class ScopedCollection extends Collection

  @fromData: (request, data) ->
    new ScopedCollection request, new Collection().deserialize(data)

  constructor: (@_request, collection) ->
    @href = collection.href
    @links = collection.links
    @queries = collection.queries
    @commands = collection.commands
    @template = collection.template
    if collection.items
      @items = Item.fromArray @_request, collection.items

  # Save an item to the collection
  save: (item, callback) ->
    item = Item.create(@_request, item) unless item instanceof Item
    method = if item.href then 'put' else 'post'
    data = item.serialize @template
    @_request(method, item.href or @href, data).then((xhr) ->
      if (items = xhr.response?.collection?.items)
        if items.length > 1
          Item.fromArray items
        else if items.length
          item.deserialize xhr.response
    ).callback callback

  # Load a link as an array of items
  loadItems: (linkName, callback) ->
    @links.loadItems @_request, linkName, callback

  # Load a link as a single item
  loadItem: (linkName, callback) ->
    @links.loadItem @_request, linkName, callback

  # Query the collection with a given query and parameters
  queryItems: (queryName, params, callback) ->
    @queries.loadItems @_request, queryName, params, callback

  # Query the collection with a given query and parameters
  queryItem: (queryName, params, callback) ->
    @queries.loadItem @_request, queryName, params, callback

  # Execute a command on the collection with the given parameters
  exec: (commandName, params, callback) ->
    @commands.exec @_request, commandName, params, callback



# A representation of a Collection+JSON item
class Item

  @create: (request, data) ->
    new Item(request, data)

  @fromArray: (request, array) ->
    if Array.isArray array
      array.map (data) ->
        Item.fromData(request, data)
    else
      array

  @fromData: (request, data) ->
    if data.collection or data.data
      @create(request).deserialize(data)
    else
      @create(request, data)

  constructor: (@_request, data) ->
    if typeof data is 'string'
      @href = data
    else if data and typeof data is 'object'
      copy data, this
    @links = new MetaList(data?.links)

  # Deserialize the data from the server into this item object
  deserialize: (data) ->
    data = data.collection.items?[0] if data?.collection
    return unless data
    @href = data.href
    @links.deserialize data.links
    for prop in data.data
      value = prop.value
      if prop.type is 'DateTime' and value
        [year, month, day, hour, minute, second] =
          value.split(/-|T|:|\+|Z/).slice(0, 6)
        value = new Date(year, month - 1, day, hour, minute, second)

      if prop.name is 'type'
        value = camelize(value)
        # TODO remove this line once type is switched to snake case
        value = value[0].toLowerCase() + value.slice(1)

      @[camelize prop.name] = value
    this

  # Serialize the data into an object to send to the server for saving
  serialize: (template) ->
    unless template?.length
      throw new TSError 'You must provide the collection\'s template'
    fields = []
    template.forEach (prop) =>
      value = @[camelize prop.name]
      if prop.name is 'type'
        value = underscore value
      if value
        fields.push name: prop.name, value: value
    template: data: fields

  # Load a link as an array of items
  loadItems: (linkName, callback) ->
    @links.loadItems @_request, linkName, callback

  # Load a link as a single item
  loadItem: (linkName, callback) ->
    @links.loadItem @_request, linkName, callback

  # Delete this item
  delete: (params, callback) ->
    if typeof params is 'function'
      callback = params
      params = null
    
    if params
      fields = []
      for own key, value of params
        fields.push name: underscore(key), value: value
      data = template: data: fields
    @_request.delete(@href, data).callback callback



# Handles lists of links, queries, and commands
class MetaList
  constructor: (data) ->
    copy data, this if data

  # Deserialize the data from the server into this list object
  deserialize: (data) ->
    return unless Array.isArray data

    for entry in data
      params = {}
      if Array.isArray entry.data
        for param in entry.data
          params[camelize param.name] = param.value

      # TODO remove this once refreshments has been renamed
      entry.rel = 'assignments' if entry.rel is 'refreshments'
      @[camelize entry.rel] = href: entry.href, params: params

  # Checks whether a given link, query, or command exists
  has: (rel) ->
    @hasOwnProperty rel

  # Returns the href of a given entry
  href: (rel) ->
    @[rel]?.href

  # Iterates over each entry calling the given function and returning the
  # results as an array. The iterator has the signature
  # `function(rel, href, params) {}`
  each: (iterator) ->
    for own rel, entry of this
      iterator rel, entry.href, entry.params

  # Load a link or query as an array of items
  loadItems: (request, rel, params, callback) ->
    if typeof params is 'function'
      callback = params
      params = undefined
    @_request(request, 'get', rel, params, 'items').callback callback

  # Load a link or query as a single item
  loadItem: (request, rel, params, callback) ->
    if typeof params is 'function'
      callback = params
      params = undefined
    @_request(request, 'get', rel, params, 'item').callback callback

  # Execute a command with the given parameters
  exec: (request, rel, params, callback) ->
    if typeof params is 'function'
      callback = params
      params = undefined
    @_request(request, 'post', rel, params, 'items').callback callback

  # Private method to run links
  _request: (request, method, rel, params, type) ->
    unless (entry = @[rel])
      throw new TSError "Unable to find rel '#{rel}'"

    if params
      data = {}
      for own key, value of params
        if entry.params.hasOwnProperty(key)
          data[underscore key] = value

    request(method, entry.href, data).then (xhr) ->
      items = Item.fromArray(request, xhr.response.collection?.items) or []
      if type is 'item' then items.pop() else items


# Utility functions
copy = (from, to) ->
  Object.keys(from).forEach (key) ->
    return if typeof value is 'function' or key.charAt(0) is '_'
    to[key] = from[key]
  to

camelize = (str) ->
  str.replace /[-_]+(\w)/g, (_, char) ->
    char.toUpperCase()

underscore = (str) ->
  str.replace /[A-Z]/g, (char) ->
    '_' + char.toLowerCase()



exports.Collection = Collection
exports.ScopedCollection = ScopedCollection
exports.Item = Item
exports.MetaList = MetaList