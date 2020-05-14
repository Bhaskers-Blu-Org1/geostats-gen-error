using Pkg; Pkg.instantiate()

using GeoStats
using DensityRatioEstimation
using LossFunctions
using ProgressMeter
using DataFrames
using MLJ, CSV
using Random

# reproducible results
Random.seed!(123)

# estimators of generalization error
error_cv( m, p, k, ℒ) = error(PointwiseLearn(m), p, CrossValidation(k, loss=ℒ))
error_bcv(m, p, r, ℒ) = error(PointwiseLearn(m), p, BlockCrossValidation(r, loss=ℒ))
error_drv(m, p, k, ℒ, σ=2.0) = error(PointwiseLearn(m), p, DensityRatioValidation(k, loss=ℒ, estimator=LSIF(σ=σ,b=10)))

# true error (known labels)
function error_empirical(m, p, ℒ)
  results = map(outputvars(task(p))) do var
    y = targetdata(p)[var]
    ŷ = solve(p, PointwiseLearn(m))[var]
    var => LossFunctions.value(ℒ[var], y, ŷ, AggMode.Mean())
  end
  Dict(results)
end

function experiment(m, p, σ, rᵦ, k, ℒ)
    # try different error estimates
    cv  = error_cv(m, p, k, ℒ)
    bcv = error_bcv(m, p, rᵦ, ℒ)
    drv = error_drv(m, p, k, ℒ, σ)

    # true error
    actual = error_empirical(m, p, ℒ)
    map(outputvars(task(p))) do var
      (rᵦ=rᵦ, k=k, CV=cv[var], BCV=bcv[var], DRV=drv[var], DRV_SIGMA=σ,
       ACTUAL=actual[var], MODEL=info(m).name, TARGET=var)
    end
end

# -------------
# MAIN SCRIPT
# -------------

# read/clean raw data
println("Read/clean raw data")
df = CSV.read("data/new_zealand/logs_no_duplicates.csv")
df = df[:,[:X,:Y,:Z,:GR,:SP,:DENS,:NEUT,:DTC,:FORMATION,:ONSHORE]]
numeric=[:GR,:SP,:DENS,:NEUT,:DTC]
dropmissing!(df)
categorical!(df, :FORMATION)
categorical!(df, :ONSHORE)

# define spatial data
wells = GeoDataFrame(df, [:X,:Y,:Z])

# group formations in terms of number of points
formations = groupby(wells, :FORMATION)
ind = sortperm(npoints.(formations), rev=true)
G1 = ind[1:2]
G2 = ind[3:4]
G3 = ind[5:end]

# only consider formations in G1
Ω = DataCollection(formations[G1])

# split onshore (True) vs. offshore (False)
onoff = groupby(Ω, :ONSHORE)
ordered = sortperm(onoff[:values], rev=true)
Ωs, Ωt = onoff[ordered]

Ωs = sample(Ωs, 10000)
Ωt = sample(Ωt,  2000)
data_Ωs = OrderedDict{Symbol,AbstractArray}(v => Ωs[v] for (v,V) in variables(Ωs))
data_Ωt = OrderedDict{Symbol,AbstractArray}(v => Ωt[v] for (v,V) in variables(Ωt))

new_Ωs = PointSetData(data_Ωs, coordinates(Ωs))
new_Ωt = PointSetData(data_Ωt, coordinates(Ωt))

# logs used in the experiment
logs = [:GR,:SP,:DENS,:NEUT,:DTC]

rᵦ = 500 # TODO: variography
k  = length(GeoStats.partition(Ωs, BlockPartitioner(rᵦ)))

# ---------------
# CLASSIFICATION
# ---------------
println("Classification")
t = ClassificationTask((:GR,:SP,:DENS,:DTC,:NEUT), :FORMATION)
p = LearningProblem(new_Ωs, new_Ωt, t)

@load DecisionTreeClassifier
@load KNNClassifier

ℒ = Dict(:FORMATION => MisclassLoss())

# parameter ranges
mrange = [DecisionTreeClassifier(),KNNClassifier()]
σrange = [1.,5.,10.,15.,20.,25.]

# experiment iterator and progress
iterator = Iterators.product(mrange, σrange)
progress = Progress(length(iterator), "New Zealand classification:")

# return missing in case of failure
skip = e -> (println("Skipped: $e"); missing)

# perform experiments
@time cresults = progress_pmap(iterator, progress=progress,
                        on_error=skip) do (m, σ)
  experiment(m, p, σ, rᵦ, k, ℒ)
end

# -----------
# REGRESSION
# -----------
println("Regression")
@load LinearRegressor pkg="MLJLinearModels"
@load DecisionTreeRegressor pkg="DecisionTree"
@load RandomForestRegressor pkg="DecisionTree"
@load KNNRegressor

# parameter ranges
mrange = [LinearRegressor(),DecisionTreeRegressor(),
          RandomForestRegressor(),KNNRegressor()]
vrange = [:GR]

# experiment iterator and progress
iterator = Iterators.product(mrange, σrange, vrange)
progress = Progress(length(iterator), "New Zealand regression:")

# perform experiments
@time rresults = progress_pmap(iterator, progress=progress,
                        on_error=skip) do (m, σ, v)
  t = RegressionTask(numeric[numeric .!= v], v)
  p = LearningProblem(new_Ωs, new_Ωt, t)
  ℒ = Dict(v => L2DistLoss())
  experiment(m, p, σ, rᵦ, k, ℒ)
end

# merge all results into dataframe
all = vcat(cresults, rresults)
res = DataFrame(skipmissing(Iterators.flatten(all)))

println("Saving results")
# save all results to disk
fname = joinpath(@__DIR__,"results","newzealand.csv")
CSV.write(fname, res)
