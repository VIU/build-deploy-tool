package generator

import (
	"encoding/json"
	"reflect"
	"testing"
	"time"

	composetypes "github.com/compose-spec/compose-go/types"
	"github.com/uselagoon/build-deploy-tool/internal/dbaasclient"
	"github.com/uselagoon/build-deploy-tool/internal/helpers"
	"github.com/uselagoon/build-deploy-tool/internal/lagoon"
)

func Test_composeToServiceValues(t *testing.T) {
	type args struct {
		lYAML                *lagoon.YAML
		buildValues          *BuildValues
		composeService       string
		composeServiceValues composetypes.ServiceConfig
	}
	tests := []struct {
		name    string
		args    args
		want    ServiceValues
		wantErr bool
	}{
		{
			name: "test1",
			args: args{
				lYAML: &lagoon.YAML{
					Environments: lagoon.Environments{
						"main": lagoon.Environment{},
					},
				},
				buildValues: &BuildValues{
					Environment:          "main",
					Branch:               "main",
					BuildType:            "branch",
					ServiceTypeOverrides: &lagoon.EnvironmentVariable{},
				},
				composeService: "nginx",
				composeServiceValues: composetypes.ServiceConfig{
					Labels: composetypes.Labels{
						"lagoon.type": "nginx",
					},
				},
			},
			want: ServiceValues{
				Name:                       "nginx",
				OverrideName:               "nginx",
				Type:                       "nginx",
				AutogeneratedRoutesEnabled: true,
				AutogeneratedRoutesTLSAcme: true,
			},
		},
		{
			name: "test2 - override name",
			args: args{
				lYAML: &lagoon.YAML{
					Environments: lagoon.Environments{
						"main": lagoon.Environment{},
					},
				},
				buildValues: &BuildValues{
					Environment:          "main",
					Branch:               "main",
					BuildType:            "branch",
					ServiceTypeOverrides: &lagoon.EnvironmentVariable{},
				},
				composeService: "nginx",
				composeServiceValues: composetypes.ServiceConfig{
					Labels: composetypes.Labels{
						"lagoon.type": "nginx",
						"lagoon.name": "nginx-php",
					},
				},
			},
			want: ServiceValues{
				Name:                       "nginx",
				OverrideName:               "nginx-php",
				Type:                       "nginx",
				AutogeneratedRoutesEnabled: true,
				AutogeneratedRoutesTLSAcme: true,
			},
		},
		{
			name: "test3 - lagoon.yml type override",
			args: args{
				lYAML: &lagoon.YAML{
					Environments: lagoon.Environments{
						"main": lagoon.Environment{
							Types: map[string]string{
								"nginx": "nginx-php-persistent",
							},
						},
					},
				},
				buildValues: &BuildValues{
					Environment:          "main",
					Branch:               "main",
					BuildType:            "branch",
					ServiceTypeOverrides: &lagoon.EnvironmentVariable{},
				},
				composeService: "nginx",
				composeServiceValues: composetypes.ServiceConfig{
					Labels: composetypes.Labels{
						"lagoon.type": "nginx-php",
					},
				},
			},
			want: ServiceValues{
				Name:                       "nginx",
				OverrideName:               "nginx",
				Type:                       "nginx-php-persistent",
				AutogeneratedRoutesEnabled: true,
				AutogeneratedRoutesTLSAcme: true,
				BackupsEnabled:             true,
			},
		},
		{
			name: "test4 - variable servicetypes type override",
			args: args{
				lYAML: &lagoon.YAML{
					Environments: lagoon.Environments{
						"main": lagoon.Environment{},
					},
				},
				buildValues: &BuildValues{
					Environment: "main",
					Branch:      "main",
					BuildType:   "branch",
					ServiceTypeOverrides: &lagoon.EnvironmentVariable{
						Name:  "LAGOON_SERVICE_TYPES",
						Value: "nginx:nginx-php-persistent,mariadb:mariadb-dbaas",
					},
				},
				composeService: "nginx",
				composeServiceValues: composetypes.ServiceConfig{
					Labels: composetypes.Labels{
						"lagoon.type": "nginx-php",
					},
				},
			},
			want: ServiceValues{
				Name:                       "nginx",
				OverrideName:               "nginx",
				Type:                       "nginx-php-persistent",
				AutogeneratedRoutesEnabled: true,
				AutogeneratedRoutesTLSAcme: true,
				BackupsEnabled:             true,
			},
		},
		{
			name: "test5 - additional labels",
			args: args{
				lYAML: &lagoon.YAML{
					Environments: lagoon.Environments{
						"main": lagoon.Environment{},
					},
				},
				buildValues: &BuildValues{
					Environment:          "main",
					Branch:               "main",
					BuildType:            "branch",
					ServiceTypeOverrides: &lagoon.EnvironmentVariable{},
				},
				composeService: "nginx",
				composeServiceValues: composetypes.ServiceConfig{
					Labels: composetypes.Labels{
						"lagoon.type":                        "nginx",
						"lagoon.autogeneratedroute":          "false",
						"lagoon.autogeneratedroute.tls-acme": "false",
					},
				},
			},
			want: ServiceValues{
				Name:                       "nginx",
				OverrideName:               "nginx",
				Type:                       "nginx",
				AutogeneratedRoutesEnabled: false,
				AutogeneratedRoutesTLSAcme: false,
			},
		},
		{
			name: "test6 - lagoon.yml additional fields",
			args: args{
				lYAML: &lagoon.YAML{
					Routes: lagoon.Routes{
						Autogenerate: lagoon.Autogenerate{
							Enabled: helpers.BoolPtr(false),
						},
					},
					Environments: lagoon.Environments{
						"main": lagoon.Environment{
							AutogenerateRoutes: helpers.BoolPtr(true),
						},
					},
				},
				buildValues: &BuildValues{
					Environment:          "main",
					Branch:               "main",
					BuildType:            "branch",
					ServiceTypeOverrides: &lagoon.EnvironmentVariable{},
				},
				composeService: "nginx",
				composeServiceValues: composetypes.ServiceConfig{
					Labels: composetypes.Labels{
						"lagoon.type": "nginx-php",
					},
				},
			},
			want: ServiceValues{
				Name:                       "nginx",
				OverrideName:               "nginx",
				Type:                       "nginx-php",
				AutogeneratedRoutesEnabled: true,
				AutogeneratedRoutesTLSAcme: true,
			},
		},
		{
			name: "test7 - lagoon.yml additional fields pullrequest",
			args: args{
				lYAML: &lagoon.YAML{
					Routes: lagoon.Routes{
						Autogenerate: lagoon.Autogenerate{
							Enabled:           helpers.BoolPtr(true),
							AllowPullRequests: helpers.BoolPtr(false),
						},
					},
					Environments: lagoon.Environments{
						"main": lagoon.Environment{
							AutogenerateRoutes: helpers.BoolPtr(true),
						},
					},
				},
				buildValues: &BuildValues{
					Environment:          "pr-123",
					Branch:               "pr-123",
					BuildType:            "pullrequest",
					ServiceTypeOverrides: &lagoon.EnvironmentVariable{},
				},
				composeService: "nginx",
				composeServiceValues: composetypes.ServiceConfig{
					Labels: composetypes.Labels{
						"lagoon.type": "nginx-php",
					},
				},
			},
			want: ServiceValues{
				Name:                       "nginx",
				OverrideName:               "nginx",
				Type:                       "nginx-php",
				AutogeneratedRoutesEnabled: false,
				AutogeneratedRoutesTLSAcme: true,
			},
		},
		{
			name: "test8 - no labels, no service",
			args: args{
				lYAML: &lagoon.YAML{
					Routes: lagoon.Routes{
						Autogenerate: lagoon.Autogenerate{
							Enabled:           helpers.BoolPtr(true),
							AllowPullRequests: helpers.BoolPtr(false),
						},
					},
					Environments: lagoon.Environments{
						"main": lagoon.Environment{
							AutogenerateRoutes: helpers.BoolPtr(true),
						},
					},
				},
				buildValues: &BuildValues{
					Environment:          "pr-123",
					Branch:               "pr-123",
					BuildType:            "pullrequest",
					ServiceTypeOverrides: &lagoon.EnvironmentVariable{},
				},
				composeService:       "nginx",
				composeServiceValues: composetypes.ServiceConfig{},
			},
			want:    ServiceValues{},
			wantErr: true,
		},
		{
			name: "test9 - type none, no service",
			args: args{
				lYAML: &lagoon.YAML{
					Routes: lagoon.Routes{
						Autogenerate: lagoon.Autogenerate{
							Enabled:           helpers.BoolPtr(true),
							AllowPullRequests: helpers.BoolPtr(false),
						},
					},
					Environments: lagoon.Environments{
						"main": lagoon.Environment{
							AutogenerateRoutes: helpers.BoolPtr(true),
						},
					},
				},
				buildValues: &BuildValues{
					Environment:          "pr-123",
					Branch:               "pr-123",
					BuildType:            "pullrequest",
					ServiceTypeOverrides: &lagoon.EnvironmentVariable{},
				},
				composeService: "nginx",
				composeServiceValues: composetypes.ServiceConfig{
					Labels: composetypes.Labels{
						"lagoon.type": "none",
					},
				},
			},
			want: ServiceValues{},
		},
		{
			name: "test10 - mariadb to mariadb-dbaas",
			args: args{
				lYAML: &lagoon.YAML{
					Routes: lagoon.Routes{
						Autogenerate: lagoon.Autogenerate{
							Enabled:           helpers.BoolPtr(true),
							AllowPullRequests: helpers.BoolPtr(false),
						},
					},
					Environments: lagoon.Environments{
						"main": lagoon.Environment{
							AutogenerateRoutes: helpers.BoolPtr(true),
						},
					},
				},
				buildValues: &BuildValues{
					Environment:          "main",
					Branch:               "main",
					BuildType:            "branch",
					EnvironmentType:      "development",
					ServiceTypeOverrides: &lagoon.EnvironmentVariable{},
				},
				composeService: "mariadb",
				composeServiceValues: composetypes.ServiceConfig{
					Labels: composetypes.Labels{
						"lagoon.type": "mariadb",
					}},
			},
			want: ServiceValues{
				Name:                       "mariadb",
				OverrideName:               "mariadb",
				Type:                       "mariadb-dbaas",
				AutogeneratedRoutesEnabled: false,
				AutogeneratedRoutesTLSAcme: false,
				DBaaSEnvironment:           "development",
				BackupsEnabled:             true,
			},
		},
		{
			//@TODO: this should FAIL in the future https://github.com/uselagoon/build-deploy-tool/issues/56
			name: "test11 - mariadb to mariadb-single via environment override with no patching db provider",
			args: args{
				lYAML: &lagoon.YAML{
					Routes: lagoon.Routes{
						Autogenerate: lagoon.Autogenerate{
							Enabled:           helpers.BoolPtr(true),
							AllowPullRequests: helpers.BoolPtr(false),
						},
					},
					Environments: lagoon.Environments{
						"main": lagoon.Environment{
							AutogenerateRoutes: helpers.BoolPtr(true),
						},
					},
				},
				buildValues: &BuildValues{
					Environment:          "main",
					Branch:               "main",
					BuildType:            "branch",
					EnvironmentType:      "development",
					ServiceTypeOverrides: &lagoon.EnvironmentVariable{},
					DBaaSEnvironmentTypeOverrides: &lagoon.EnvironmentVariable{
						Name:  "LAGOON_DBAAS_ENVIRONMENT_TYPES",
						Value: "mariadb:development2,postgres:postgres-single",
					},
				},
				composeService: "mariadb",
				composeServiceValues: composetypes.ServiceConfig{
					Labels: composetypes.Labels{
						"lagoon.type": "mariadb",
					}},
			},
			want: ServiceValues{
				Name:                       "mariadb",
				OverrideName:               "mariadb",
				Type:                       "mariadb-single",
				AutogeneratedRoutesEnabled: false,
				AutogeneratedRoutesTLSAcme: false,
				DBaaSEnvironment:           "development2",
				BackupsEnabled:             true,
			},
		},
		{
			name: "test12 - postgres to postgres-dbaas",
			args: args{
				lYAML: &lagoon.YAML{
					Routes: lagoon.Routes{
						Autogenerate: lagoon.Autogenerate{
							Enabled:           helpers.BoolPtr(true),
							AllowPullRequests: helpers.BoolPtr(false),
						},
					},
					Environments: lagoon.Environments{
						"main": lagoon.Environment{
							AutogenerateRoutes: helpers.BoolPtr(true),
						},
					},
				},
				buildValues: &BuildValues{
					Environment:          "main",
					Branch:               "main",
					BuildType:            "branch",
					EnvironmentType:      "development",
					ServiceTypeOverrides: &lagoon.EnvironmentVariable{},
				},
				composeService: "postgres",
				composeServiceValues: composetypes.ServiceConfig{
					Labels: composetypes.Labels{
						"lagoon.type": "postgres",
					}},
			},
			want: ServiceValues{
				Name:                       "postgres",
				OverrideName:               "postgres",
				Type:                       "postgres-dbaas",
				AutogeneratedRoutesEnabled: false,
				AutogeneratedRoutesTLSAcme: false,
				DBaaSEnvironment:           "development",
				BackupsEnabled:             true,
			},
		},
		{
			name: "test13 - ckandatapusher should be python",
			args: args{
				lYAML: &lagoon.YAML{
					Environments: lagoon.Environments{
						"main": lagoon.Environment{},
					},
				},
				buildValues: &BuildValues{
					Environment:          "main",
					Branch:               "main",
					BuildType:            "branch",
					ServiceTypeOverrides: &lagoon.EnvironmentVariable{},
				},
				composeService: "python-ckan",
				composeServiceValues: composetypes.ServiceConfig{
					Labels: composetypes.Labels{
						"lagoon.type": "python-ckandatapusher",
					},
				},
			},
			want: ServiceValues{
				Name:                       "python-ckan",
				OverrideName:               "python-ckan",
				Type:                       "python",
				AutogeneratedRoutesEnabled: true,
				AutogeneratedRoutesTLSAcme: true,
			},
		},
		{
			name: "test14 - invalid service port",
			args: args{
				lYAML: &lagoon.YAML{
					Environments: lagoon.Environments{
						"main": lagoon.Environment{},
					},
				},
				buildValues: &BuildValues{
					Environment:          "main",
					Branch:               "main",
					BuildType:            "branch",
					ServiceTypeOverrides: &lagoon.EnvironmentVariable{},
				},
				composeService: "basic",
				composeServiceValues: composetypes.ServiceConfig{
					Labels: composetypes.Labels{
						"lagoon.type":         "basic",
						"lagoon.service.port": "32a12",
					},
				},
			},
			want:    ServiceValues{},
			wantErr: true,
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			ts := dbaasclient.TestDBaaSHTTPServer()
			defer ts.Close()
			tt.args.buildValues.DBaaSOperatorEndpoint = ts.URL
			tt.args.buildValues.DBaaSClient = dbaasclient.NewClient(dbaasclient.Client{
				RetryMax:     5,
				RetryWaitMin: time.Duration(10) * time.Millisecond,
				RetryWaitMax: time.Duration(50) * time.Millisecond,
			})
			got, err := composeToServiceValues(tt.args.buildValues, tt.args.lYAML, tt.args.composeService, tt.args.composeServiceValues, false)
			if (err != nil) != tt.wantErr {
				t.Errorf("composeToServiceValues() error = %v, wantErr %v", err, tt.wantErr)
				return
			}
			lValues, _ := json.Marshal(got)
			wValues, _ := json.Marshal(tt.want)
			if !reflect.DeepEqual(string(lValues), string(wValues)) {
				t.Errorf("composeToServiceValues() = %v, want %v", string(lValues), string(wValues))
			}
		})
	}
}
