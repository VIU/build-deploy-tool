package cmd

import (
	"fmt"

	"github.com/spf13/cobra"
	"github.com/uselagoon/build-deploy-tool/internal/lagoon"
)

var primaryIngressIdentify = &cobra.Command{
	Use:     "primary-ingress",
	Aliases: []string{"pi"},
	Short:   "Identify the primary ingress for a specific environment",
	RunE: func(cmd *cobra.Command, args []string) error {
		primary, _, _, err := IdentifyPrimaryIngress(false)
		if err != nil {
			return err
		}
		fmt.Println(primary)
		return nil
	},
}

// IdentifyPrimaryIngress .
func IdentifyPrimaryIngress(debug bool) (string, []string, []string, error) {
	activeEnv := false
	standbyEnv := false

	lagoonEnvVars := []lagoon.EnvironmentVariable{}
	lagoonValues := lagoon.BuildValues{}
	lYAML := lagoon.YAML{}
	autogenRoutes := &lagoon.RoutesV2{}
	mainRoutes := &lagoon.RoutesV2{}
	activeStanbyRoutes := &lagoon.RoutesV2{}
	err := collectBuildValues(debug, &activeEnv, &standbyEnv, &lagoonEnvVars, &lagoonValues, &lYAML, autogenRoutes, mainRoutes, activeStanbyRoutes)
	if err != nil {
		return "", []string{}, []string{}, err
	}

	return lagoonValues.Route, lagoonValues.Routes, lagoonValues.AutogeneratedRoutes, nil

}

func generateRoutes(lagoonEnvVars []lagoon.EnvironmentVariable,
	lagoonValues lagoon.BuildValues,
	lYAML lagoon.YAML,
	autogenRoutes *lagoon.RoutesV2, mainRoutes *lagoon.RoutesV2, activeStanbyRoutes *lagoon.RoutesV2,
	activeEnv, standbyEnv, debug bool,
) (string, []string, []string, error) {
	var err error
	primary := ""
	remainders := []string{}
	autogen := []string{}
	prefix := "https://"

	// collect the autogenerated routes
	err = generateAutogenRoutes(lagoonEnvVars, &lYAML, &lagoonValues, autogenRoutes)
	if err != nil {
		return "", []string{}, []string{}, fmt.Errorf("couldn't unmarshal routes from Lagoon API, is it actually JSON that has been base64 encoded?: %v", err)
	}
	// get the first route from the list of routes
	if len(autogenRoutes.Routes) > 0 {
		rangeVal := len(autogenRoutes.Routes) - 1
		autogen = append(autogen, fmt.Sprintf("%s%s", prefix, autogenRoutes.Routes[0].Domain))
		for i := 1; i <= rangeVal; i++ {
			remainders = append(remainders, fmt.Sprintf("%s%s", prefix, autogenRoutes.Routes[i].Domain))
			autogen = append(autogen, fmt.Sprintf("%s%s", prefix, autogenRoutes.Routes[i].Domain))
			for a := 0; a < len(autogenRoutes.Routes[i].AlternativeNames); a++ {
				autogen = append(autogen, fmt.Sprintf("%s%s", prefix, autogenRoutes.Routes[i].AlternativeNames[a]))
			}
		}
		for a := 0; a < len(autogenRoutes.Routes[0].AlternativeNames); a++ {
			autogen = append(autogen, fmt.Sprintf("%s%s", prefix, autogenRoutes.Routes[0].AlternativeNames[a]))
		}
		primary = fmt.Sprintf("%s%s", prefix, autogenRoutes.Routes[0].Domain)
	}

	// handle routes from the .lagoon.yml and the API specifically
	err = generateIngress(lagoonValues, lYAML, lagoonEnvVars, mainRoutes, debug)
	if err != nil {
		return "", []string{}, []string{}, fmt.Errorf("couldn't generate and merge routes: %v", err)
	}

	// get the first route from the list of routes, replace the previous one if necessary
	if len(mainRoutes.Routes) > 0 {
		if primary != "" {
			remainders = append(remainders, primary)
		}
		rangeVal := len(mainRoutes.Routes) - 1
		for i := 1; i <= rangeVal; i++ {
			remainders = append(remainders, fmt.Sprintf("%s%s", prefix, mainRoutes.Routes[i].Domain))
			for a := 0; a < len(mainRoutes.Routes[i].AlternativeNames); a++ {
				remainders = append(autogen, fmt.Sprintf("%s%s", prefix, mainRoutes.Routes[i].AlternativeNames[a]))
			}
		}
		for a := 0; a < len(mainRoutes.Routes[0].AlternativeNames); a++ {
			remainders = append(autogen, fmt.Sprintf("%s%s", prefix, mainRoutes.Routes[0].AlternativeNames[a]))
		}
		primary = fmt.Sprintf("%s%s", prefix, mainRoutes.Routes[0].Domain)
	}

	if activeEnv || standbyEnv {
		// active/standby routes should not be changed by any environment defined routes.
		// generate the templates for these independently of any previously generated routes,
		// this WILL overwrite previously created templates ensuring that anything defined in the `production_routes`
		// section are created correctly ensuring active/standby will work
		*activeStanbyRoutes = generateActiveStandby(activeEnv, standbyEnv, lagoonEnvVars, lYAML)
		// get the first route from the list of routes, replace the previous one if necessary
		if len(activeStanbyRoutes.Routes) > 0 {
			if primary != "" {
				remainders = append(remainders, primary)
			}
			rangeVal := len(activeStanbyRoutes.Routes) - 1
			for i := 1; i <= rangeVal; i++ {
				remainders = append(remainders, fmt.Sprintf("%s%s", prefix, activeStanbyRoutes.Routes[i].Domain))
				for a := 0; a < len(activeStanbyRoutes.Routes[i].AlternativeNames); a++ {
					remainders = append(autogen, fmt.Sprintf("%s%s", prefix, activeStanbyRoutes.Routes[i].AlternativeNames[a]))
				}
			}
			for a := 0; a < len(activeStanbyRoutes.Routes[0].AlternativeNames); a++ {
				remainders = append(autogen, fmt.Sprintf("%s%s", prefix, activeStanbyRoutes.Routes[0].AlternativeNames[a]))
			}
			primary = fmt.Sprintf("%s%s", prefix, activeStanbyRoutes.Routes[0].Domain)
		}
	}

	return primary, remainders, autogen, nil
}

func init() {
	identifyCmd.AddCommand(primaryIngressIdentify)
}
