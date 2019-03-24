# developed with Julia 1.0.3
#
# functions for Stochastic Dynamic Programming applied to the EMS problem


using StoOpt, ParserSchneider
using Dates

function is_summer(date::DateTime)
	Dates.month(date) in 5:9
end

function is_weekend(date::DateTime)
	Dates.dayofweek(date) in 6:7
end

function compute_offline_laws(data_path)

	pv, load, filters = load_train_data(data_path)
	w = load - pv

	law_summer_weekday = Noise(w[:, intersect(filters["summer"], filters["weekday"])], k)
	law_summer_weekend = Noise(w[:, intersect(filters["summer"], filters["weekend"])], k)
	law_winter_weekday = Noise(w[:, intersect(filters["winter"], filters["weekday"])], k)
	law_winter_weekend = Noise(w[:, intersect(filters["winter"], filters["weekend"])], k)

	offline_laws = Dict("summer"=>Dict("weekday"=>law_summer_weekday, 
		"weekend"=>law_summer_weekend), "winter"=>Dict("weekday"=>law_winter_weekday,
			"weekend"=>law_winter_weekend))

	return offline_laws

end

function compute_noise(t0::DateTime, laws::Dict)

	w = Array{Float64}(undef, 0, 0)
	pw = Array{Float64}(undef, 0, 0)

	season = is_summer(t0) ? "summer" : "winter"
	weekday = is_weekend(t0) ? "weekend" : "weekday"
	hour = Dates.hour(t0)
	minute = Dates.minute(t0)
	quater = Int(hour*4 + minute/15) + 1

	law = laws[season][weekday]
	w = law.w[quater:end, :]
	pw = law.pw[quater:end, :]

	for k in 1:9
		day = t0 + Dates.Day(k)
		season = is_summer(day) ? "summer" : "winter"
		weekday = is_weekend(day) ? "weekend" : "weekday"
		law = laws[season][weekday]

		w = vcat(w, law.w)
		pw = vcat(pw, law.pw)
	end

	if quater > 1
		day = t0 + Dates.Day(10)
		season = is_summer(day) ? "summer" : "winter"
		weekday = is_weekend(day) ? "weekend" : "weekday"
		law = laws[season][weekday]
		w = vcat(w, law.w[1:quater-1, :])
		pw = vcat(pw, law.pw[1:quater-1, :])
	end

	return Noise(w, pw)

end

function load_vopt(period::SubString{String}, period_prices::Price, periods_data::Dict,
	path_to_vopt::String)

	t0 = periods_data[period]["t0"]

	for past_period in [string(i) for i in 1:parse(Int64, period)-1]
		start = periods_data[past_period]["t0"]
		if Dates.dayofweek(t0) == Dates.dayofweek(start) &&
			Dates.Time(t0) == Dates.Time(start) &&
			is_summer(t0) == is_summer(start)

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

function dynamics(x, u, w)
        return x + (rc.x*max.(u, 0) - max.(-u, 0)/rd.x)*u_max.x/capacity.x
end

function stage_cost(price, x, u, w)
	# return Float64
	u = Float64(u...)
    return price[1]*max(0., w[1] + u*u_max.x) - price[2]*max(0., - (w[1] + u*u_max.x))
end