# ------------------------------------------------------------------
# Licensed under the MIT License. See LICENSE in the project root.
# ------------------------------------------------------------------

"""
    GeoStatsModel

A geostatistical model that predicts variables over geometries
of a geospatial domain near other geometries with samples.
"""
abstract type GeoStatsModel end

"""
    range(model)

Return the range of the geostatistical `model`, which is the
characteristic length after which the model ignores any data.

For example, the Kriging model has the same range of the
underlying geostatistical function.
"""
Base.range(::GeoStatsModel) = Inf * u"m"

"""
    scale(model, factor)

Scale the geostatistical `model` with a strictly positive
scaling `factor`.
"""
scale(model, _) = model

"""
    fit(model, geotable)

Fit geostatistical `model` to `geotable` and return a fitted
geostatistical model.
"""
function fit end

"""
    FittedGeoStatsModel

A fitted geostatistical model obtained with the [`fit`](@ref) function
on a [`GeoStatsModel`](@ref).
"""
abstract type FittedGeoStatsModel end

"""
    predict(model, vars, gₒ)

Predict one or multiple variables `vars` at geometry `gₒ` with
given geostatistical `model`.
"""
predict(model::FittedGeoStatsModel, var::AbstractString, gₒ) = predict(model, Symbol(var), gₒ)
function predict(model::FittedGeoStatsModel, vars, gₒ)
  if length(vars) > 1
    throw(ArgumentError("cannot use univariate model to predict multiple variables"))
  else
    [predict(model, first(vars), gₒ)]
  end
end

"""
    predictprob(model, vars, gₒ)

Predict distribution of one or multiple variables `vars` at
geometry `gₒ` with given geostatistical `model`.
"""
predictprob(model::FittedGeoStatsModel, var::AbstractString, gₒ) = predictprob(model, Symbol(var), gₒ)
function predictprob(model::FittedGeoStatsModel, vars, gₒ)
  if length(vars) > 1
    throw(ArgumentError("cannot use univariate model to predict multiple variables"))
  else
    product_distribution([predictprob(model, first(vars), gₒ)])
  end
end

"""
    status(fitted)

Return the status of the `fitted` geostatistical model.
(e.g. the factorization of the linear system was successful)
"""
function status end

"""
    fitpredict(model, geotable, domain; [options])

Fit geostatistical `model` to `geotable` and predict all
variables on `domain` using a set of `options`.

## Options

* `path`         - Path over the domain (default to `LinearPath()`)
* `point`        - Perform interpolation on point support (default to `true`)
* `prob`         - Perform probabilistic interpolation (default to `false`)
* `neighbors`    - Whether or not to use neighborhood (default to `true`)
* `minneighbors` - Minimum number of neighbors (default to `1`)
* `maxneighbors` - Maximum number of neighbors (default to `10`)
* `neighborhood` - Search neighborhood (default to `nothing`)
* `distance`     - Distance to find nearest neighbors (default to `Euclidean()`)
"""
function fitpredict(
  model::GeoStatsModel,
  dat::AbstractGeoTable,
  dom::Domain;
  path=LinearPath(),
  point=true,
  prob=false,
  neighbors=true,
  minneighbors=1,
  maxneighbors=10,
  neighborhood=nothing,
  distance=Euclidean()
)
  # point or volume support
  pdat = point ? _pointsupport(dat) : dat

  # scale objects for numerical stability
  smodel, sdat, sdom, sneigh = _scale(model, pdat, dom, neighborhood)

  # choose between full and neighbor-based algorithm
  pred = if neighbors
    fitpredictneigh(smodel, sdat, sdom, path, point, prob, minneighbors, maxneighbors, sneigh, distance)
  else
    fitpredictfull(smodel, sdat, sdom, path, point, prob)
  end

  # georeference over original domain
  georef(pred, dom)
end

function fitpredictneigh(model, dat, dom, path, point, prob, minneighbors, maxneighbors, neighborhood, distance)
  # fix neighbors limits
  nobs = nrow(dat)
  if maxneighbors > nobs || maxneighbors < 1
    maxneighbors = nobs
  end
  if minneighbors > maxneighbors || minneighbors < 1
    minneighbors = 1
  end

  # determine bounded search method
  searcher = if isnothing(neighborhood)
    # nearest neighbor search with a metric
    KNearestSearch(domain(dat), maxneighbors; metric=distance)
  else
    # neighbor search with ball neighborhood
    KBallSearch(domain(dat), maxneighbors, neighborhood)
  end

  # pre-allocate memory for neighbors
  thread_neighbors = [Vector{Int}(undef, maxneighbors) for _ in 1:Threads.nthreads()]

  # traverse domain with given path
  inds = traverse(dom, path)

  # prediction function
  predfun = prob ? _marginals ∘ predictprob : predict

  # predict variables
  cols = Tables.columns(values(dat))
  vars = Tables.columnnames(cols)

  # Pre-allocate results vector
  pred = Vector{NamedTuple}(undef, length(inds))

  Threads.@threads for i in eachindex(inds)
    ind = inds[i]
    # centroid of estimation
    center = centroid(dom, ind)

    # find neighbors with data
    neighbors = thread_neighbors[Threads.threadid()]
    nneigh = search!(neighbors, center, searcher)

    # predict if enough neighbors
    if nneigh ≥ minneighbors
      # final set of neighbors
      ninds = view(neighbors, 1:nneigh)

      # view neighborhood with data
      samples = Tables.subset(dat, collect(ninds))

      # fit model to samples
      fmodel = fit(model, samples)

      # save prediction
      geom = point ? center : dom[ind]
      vals = predfun(fmodel, vars, geom)
    else
      # missing prediction
      vals = fill(missing, length(vars))
    end
    pred[i] = (; zip(vars, vals)...)
  end

  # convert to original table type
  pred |> Tables.materializer(values(dat))
end

function fitpredictfull(model, dat, dom, path, point, prob)
  # traverse domain with given path
  inds = traverse(dom, path)

  # prediction function
  predfun = prob ? _marginals ∘ predictprob : predict

  # fit model to data
  fmodel = fit(model, dat)

  # predict variables
  cols = Tables.columns(values(dat))
  vars = Tables.columnnames(cols)
  pred = @inbounds map(inds) do ind
    geom = point ? centroid(dom, ind) : dom[ind]
    vals = predfun(fmodel, vars, geom)
    (; zip(vars, vals)...)
  end

  # convert to original table type
  pred |> Tables.materializer(values(dat))
end

# ----------------
# IMPLEMENTATIONS
# ----------------

include("nn.jl")
include("idw.jl")
include("lwr.jl")
include("poly.jl")
include("krig.jl")

# -----------------
# HELPER FUNCTIONS
# -----------------

function _pointsupport(dat)
  tab = values(dat)
  dom = domain(dat)
  pset = PointSet(centroid(dom, i) for i in 1:nelements(dom))
  georef(tab, pset)
end

function _scale(model, dat, dom, neigh)
  α₁ = _scalefactor(model)
  α₂ = _scalefactor(domain(dat))
  α₃ = _scalefactor(dom)
  α = inv(max(α₁, α₂, α₃))

  smodel = GeoStatsModels.scale(model, α)
  sdat = dat |> Scale(α)
  sdom = dom |> Scale(α)
  sneigh = isnothing(neigh) ? nothing : α * neigh

  smodel, sdat, sdom, sneigh
end

function _scalefactor(domain::Domain)
  pmin, pmax = extrema(boundingbox(domain))
  cmin = abs.(to(pmin))
  cmax = abs.(to(pmax))
  ustrip(max(cmin..., cmax...))
end

function _scalefactor(model::GeoStatsModel)
  r = ustrip(range(model))
  isinf(r) ? one(r) : r
end

_marginals(dist::UnivariateDistribution) = (dist,)
_marginals(dist::MvNormal) = Normal.(mean(dist), var(dist))
