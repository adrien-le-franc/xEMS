# developed with Julia 1.0.3
#
# functions for Stochastic Dynamic Programming with AR(1) applied to the EMS problem


using StoOpt, ParserSchneider
using Dates
using LinearAlgebra

### set parameters, cost and dynamics for method

const states = Grid(0:0.05:1, 0:0.05:1)
const state_steps = StoOpt.grid_steps(states)
const w_max = Ref(0.)
const w_min = Ref(0.)

const k = 5
const offline_weights = Ref(Dict())
const period_weights = Ref(Array{Float64}(undef, 0, 0))

const use_forecast = true

function dynamics(t, x, u, w)

	x1, x2 = x
	x1 = x1 + (rc.x*max.(u[1], 0) - max.(-u[1], 0)/rd.x)*u_max.x/capacity.x

	if use_forecast
		if online.x
			w = w[1]
			if w > w_max.x
				w = w_max.x
			elseif w < w_min.x
				w = w_min.x
			end
			w = (w-w_min.x) / (w_max.x-w_min.x)
			return [x1, w[1]]
		end
	end

	# de-normalize
	x2 = (1-x2)*w_min.x + x2*w_max.x

	x2 = dot(period_weights.x[t+1, :], [x2, 1.]) + w[1]
	if x2 > w_max.x
		x2 = w_max.x
	elseif x2 < w_min.x
		x2 = w_min.x
	end

	# re-normalize
	x2 = (x2-w_min.x) / (w_max.x-w_min.x)

    return [x1, x2]

end

function stage_cost(t, price, x, u, w)
	# return Float64
	u = Float64(u...)
	x1, x2 = x

	if use_forecast
		if online.x
			return price[1]*max(0., w[1] + u*u_max.x) - price[2]*max(0., - (w[1] + u*u_max.x))
		end
	end

	x2 = (1-x2)*w_min.x + x2*w_max.x
	noise = dot(period_weights.x[t+1, :], [x2, 1.]) + w[1]
    return price[1]*max(0., noise + u*u_max.x) - price[2]*max(0., - (noise + u*u_max.x))
end

### other method related functions

function dynamics_soc(soc::Array{Float64,1}, uopt::Float64)
	return soc[1] + (rc.x*max.(uopt, 0) - max.(-uopt, 0)/rd.x)*u_max.x/capacity.x 
end

function current_state(soc::Array{Float64,1}, previous_noise::Float64)
	return [soc[1], previous_noise]
end

#### !!!! 
#function compute_online_law(t::Int64, forecast_noise::Float64)
#	return Noise(reshape([forecast_noise], (1, 1)), reshape([1.], (1, 1)))
#end

function compute_online_law(t::Int64, forecast_noise::Float64)
	if use_forecast
		return Noise(reshape([forecast_noise], (1, 1)), reshape([1.], (1, 1)))
	end
	return Noise(reshape([0.], (1, 1)), reshape([1.], (1, 1)))
end

function is_weekend(date::DateTime)
	Dates.dayofweek(date) in 6:7
end

function ar_1_regression(w::Array{Float64,2}, w_lag::Array{Float64,2})
	"""
	compute regression weight and predict w
	"""

	horizon, n = size(w)
	weights = zeros(horizon, 2)
	simulate = zeros(horizon, n)
	for t in 1:horizon
		target = reshape(w[t, :], (:, 1))
		lag_1 = hcat(reshape(w_lag[t, :], (:, 1)), ones(n, 1))
		weight = pinv(lag_1'*lag_1)*lag_1'*target
		weights[t, :] = weight
		for i in 1:size(w)[2]
			simulate[t, i] = dot(weight, [w_lag[t, i], 1.])
		end
	end

	return weights, simulate

end

function compute_offline_laws(data_path)

	pv, pv_lag, load, load_lag, filters = load_train_data_with_lags(data_path)
	w = load - pv
	w_lag = load_lag - pv_lag

	w_max.x = maximum(w)
	w_min.x = minimum(w)

	# compute regression weight and predict w
	w_weekday = w[:, filters["weekday"]]
	weights_weekday, simulate_weekday = ar_1_regression(w_weekday, w_lag[:, filters["weekday"]])
	offline_weights.x["weekday"] = weights_weekday
	w_weekend = w[:, filters["weekend"]]
	weights_weekend, simulate_weekend = ar_1_regression(w_weekend, w_lag[:, filters["weekend"]])
	offline_weights.x["weekend"] = weights_weekend

	# noise is prediction error epsilon
	epsilon_weekday = w_weekday - simulate_weekday
	law_weekday = Noise(epsilon_weekday, k)
	epsilon_weekend = w_weekend - simulate_weekend
	law_weekend = Noise(epsilon_weekend, k)

	offline_laws = Dict(Dict("weekday"=>law_weekday, "weekend"=>law_weekend))

	return offline_laws

end

function compute_noise(t0::DateTime, laws::Dict)

	w = Array{Float64}(undef, 0, 0)
	pw = Array{Float64}(undef, 0, 0)
	period_weights.x = Array{Float64}(undef, 0, 0)

	weekday = is_weekend(t0) ? "weekend" : "weekday"
	hour = Dates.hour(t0)
	minute = Dates.minute(t0)
	quater = Int(hour*4 + minute/15) + 1

	law = laws[weekday]
	w = law.w[quater:end, :]
	pw = law.pw[quater:end, :]
	period_weights.x = offline_weights.x[weekday][quater:end, :]

	for k in 1:9
		day = t0 + Dates.Day(k)
		weekday = is_weekend(day) ? "weekend" : "weekday"
		law = laws[weekday]
		w = vcat(w, law.w)
		pw = vcat(pw, law.pw)
		period_weights.x = vcat(period_weights.x, offline_weights.x[weekday])
	end

	if quater > 1
		day = t0 + Dates.Day(10)
		weekday = is_weekend(day) ? "weekend" : "weekday"
		law = laws[weekday]
		w = vcat(w, law.w[1:quater-1, :])
		pw = vcat(pw, law.pw[1:quater-1, :])
		period_weights.x = vcat(period_weights.x, offline_weights.x[weekday][1:quater-1, :])
	end

	return Noise(w, pw)

end

function load_vopt(period::SubString{String}, period_prices::Price, periods_data::Dict,
	path_to_vopt::String)

	t0 = periods_data[period]["t0"]

	for past_period in [string(i) for i in 1:parse(Int64, period)-1]
		start = periods_data[past_period]["t0"]
		if Dates.dayofweek(t0) == Dates.dayofweek(start) &&
			Dates.Time(t0) == Dates.Time(start)

			past_prices = Price(periods_data[past_period]["buy"],
				periods_data[past_period]["sell"])

			if period_prices == past_prices

				path = path_to_vopt*"/period_$(past_period).jld"
				vopt = load(path)["vopt"]
				println("Using vopt period $(past_period) for period $(period)")
				return true, vopt

			end

		end
	end

	return false, Dict()

end
