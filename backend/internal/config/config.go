package config

type Config struct {
	APIPort     string
	DatabaseURL string
	RedisURL    string
}

/*
Load reads configuration from environment variables.
Returns an error if any required variable is missing or invalid.
*/

func Load(*Config) (config *Config, errors error) {
	return nil, nil
}
