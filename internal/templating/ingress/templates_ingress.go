package routes

import (
	"fmt"
	"strconv"
	"strings"

	"github.com/uselagoon/build-deploy-tool/internal/generator"
	"github.com/uselagoon/build-deploy-tool/internal/helpers"
	"github.com/uselagoon/build-deploy-tool/internal/lagoon"
	networkv1 "k8s.io/api/networking/v1"
	apivalidation "k8s.io/apimachinery/pkg/api/validation"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	metavalidation "k8s.io/apimachinery/pkg/apis/meta/v1/validation"
	"k8s.io/apimachinery/pkg/util/validation"
	utilvalidation "k8s.io/apimachinery/pkg/util/validation"

	"sigs.k8s.io/yaml"
)

// GenerateIngressTemplate generates the lagoon template to apply.
func GenerateIngressTemplate(
	route lagoon.RouteV2,
	lValues generator.BuildValues,
) ([]byte, error) {

	// lowercase any domains then validate them
	routeDomain := strings.ToLower(route.Domain)
	if err := validation.IsDNS1123Subdomain(strings.ToLower(routeDomain)); err != nil {
		return nil, fmt.Errorf("the provided domain name %s is not valid: %v", route.Domain, err)
	}

	// truncate the route for use in labels and secretname
	truncatedRouteDomain := routeDomain
	if len(truncatedRouteDomain) >= 53 {
		subdomain := strings.Split(truncatedRouteDomain, ".")[0]
		if errs := utilvalidation.IsValidLabelValue(subdomain); errs != nil {
			subdomain = subdomain[:53]
		}
		truncatedRouteDomain = fmt.Sprintf("%s-%s", strings.Split(subdomain, ".")[0], helpers.GetMD5HashWithNewLine(routeDomain)[:5])
	}

	// create the ingress object for templating
	ingress := &networkv1.Ingress{}
	ingress.TypeMeta = metav1.TypeMeta{
		Kind:       "Ingress",
		APIVersion: "networking.k8s.io/v1",
	}
	ingress.ObjectMeta.Name = routeDomain
	if route.Autogenerated {
		// autogenerated routes just have the service name
		ingress.ObjectMeta.Name = route.LagoonService
	}
	// add the default labels
	ingress.ObjectMeta.Labels = map[string]string{
		"lagoon.sh/autogenerated":      "false",
		"helm.sh/chart":                fmt.Sprintf("%s-%s", "custom-ingress", "0.1.0"),
		"app.kubernetes.io/name":       "custom-ingress",
		"app.kubernetes.io/instance":   truncatedRouteDomain,
		"app.kubernetes.io/managed-by": "Helm",
		"lagoon.sh/service":            truncatedRouteDomain,
		"lagoon.sh/service-type":       "custom-ingress",
		"lagoon.sh/project":            lValues.Project,
		"lagoon.sh/environment":        lValues.Environment,
		"lagoon.sh/environmentType":    lValues.EnvironmentType,
		"lagoon.sh/buildType":          lValues.BuildType,
	}
	additionalLabels := map[string]string{}

	// add the default annotations
	ingress.ObjectMeta.Annotations = map[string]string{
		"kubernetes.io/tls-acme": strconv.FormatBool(*route.TLSAcme),
		"fastly.amazee.io/watch": strconv.FormatBool(route.Fastly.Watch),
		"lagoon.sh/version":      lValues.LagoonVersion,
	}
	additionalAnnotations := map[string]string{}

	if lValues.EnvironmentType == "production" {
		if route.Migrate != nil {
			additionalLabels["dioscuri.amazee.io/migrate"] = strconv.FormatBool(*route.Migrate)
		} else {
			additionalLabels["dioscuri.amazee.io/migrate"] = "false"
		}
	}
	if lValues.EnvironmentType == "production" {
		// monitoring is only available in production environments
		additionalAnnotations["monitor.stakater.com/enabled"] = "false"
		if lValues.Monitoring.Enabled && !route.Autogenerated {
			// only add the monitring annotations if monitoring is enabled
			additionalAnnotations["monitor.stakater.com/enabled"] = "true"
			additionalAnnotations["uptimerobot.monitor.stakater.com/alert-contacts"] = "unconfigured"
			if lValues.Monitoring.AlertContact != "" {
				additionalAnnotations["uptimerobot.monitor.stakater.com/alert-contacts"] = lValues.Monitoring.AlertContact
			}
			if lValues.Monitoring.StatusPageID != "" {
				additionalAnnotations["uptimerobot.monitor.stakater.com/status-pages"] = lValues.Monitoring.StatusPageID
			}
			additionalAnnotations["uptimerobot.monitor.stakater.com/interval"] = "60"
		}
		if route.MonitoringPath != "" {
			additionalAnnotations["monitor.stakater.com/overridePath"] = route.MonitoringPath
		}
	}
	if route.Fastly.ServiceID != "" {
		additionalAnnotations["fastly.amazee.io/service-id"] = route.Fastly.ServiceID
	}
	if route.Fastly.APISecretName != "" {
		additionalAnnotations["fastly.amazee.io/api-secret-name"] = route.Fastly.APISecretName
	}
	if lValues.BuildType == "branch" {
		additionalAnnotations["lagoon.sh/branch"] = lValues.Branch
	} else if lValues.BuildType == "pullrequest" {
		additionalAnnotations["lagoon.sh/prNumber"] = lValues.PRNumber
		additionalAnnotations["lagoon.sh/prHeadBranch"] = lValues.PRHeadBranch
		additionalAnnotations["lagoon.sh/prBaseBranch"] = lValues.PRBaseBranch

	}
	if *route.Insecure == "Allow" {
		additionalAnnotations["nginx.ingress.kubernetes.io/ssl-redirect"] = "false"
		additionalAnnotations["ingress.kubernetes.io/ssl-redirect"] = "false"
	} else if *route.Insecure == "Redirect" || *route.Insecure == "None" {
		additionalAnnotations["nginx.ingress.kubernetes.io/ssl-redirect"] = "true"
		additionalAnnotations["ingress.kubernetes.io/ssl-redirect"] = "true"
	}
	if lValues.EnvironmentType == "development" || *&route.Autogenerated == true {
		additionalAnnotations["nginx.ingress.kubernetes.io/server-snippet"] = "add_header X-Robots-Tag \"noindex, nofollow\";\n"
	}

	// add ingressclass support to ingress template generation
	if route.IngressClass != "" {
		ingress.Spec.IngressClassName = &route.IngressClass
		// add the certmanager ingressclass annotation
		additionalAnnotations["acme.cert-manager.io/http01-ingress-class"] = route.IngressClass
	}

	// add any additional labels
	for key, value := range additionalLabels {
		ingress.ObjectMeta.Labels[key] = value
	}
	// add any additional annotations
	for key, value := range additionalAnnotations {
		ingress.ObjectMeta.Annotations[key] = value
	}
	// add any annotations that the route had to overwrite any previous annotations
	for key, value := range route.Annotations {
		ingress.ObjectMeta.Annotations[key] = value
	}
	// add any labels that the route had to overwrite any previous labels
	for key, value := range route.Labels {
		ingress.ObjectMeta.Labels[key] = value
	}
	// validate any annotations
	if err := apivalidation.ValidateAnnotations(ingress.ObjectMeta.Annotations, nil); err != nil {
		if len(err) != 0 {
			return nil, fmt.Errorf("the annotations for %s are not valid: %v", routeDomain, err)
		}
	}
	// validate any labels
	if err := metavalidation.ValidateLabels(ingress.ObjectMeta.Labels, nil); err != nil {
		if len(err) != 0 {
			return nil, fmt.Errorf("the labels for %s are not valid: %v", routeDomain, err)
		}
	}

	// set up the secretname for tls
	if route.Autogenerated {
		// autogenerated use the service name
		ingress.Spec.TLS = []networkv1.IngressTLS{
			{
				SecretName: fmt.Sprintf("%s-tls", route.LagoonService),
			},
		}
	} else {
		// everything else uses the truncated
		ingress.Spec.TLS = []networkv1.IngressTLS{
			{
				// use the truncated route domain here as we add `-tls`
				// if a domain that is 253 chars long is used this will then exceed
				// the 253 char limit on kubernetes names
				SecretName: fmt.Sprintf("%s-tls", truncatedRouteDomain),
			},
		}
	}

	// autogenerated domains that are too long break when creating the acme challenge k8s resource
	// this injects a shorter domain into the tls spec that is used in the k8s challenge
	// use the compose service name to check this, as this is how Services are populated from the compose generation
	for _, service := range lValues.Services {
		if service.Name == route.ComposeService {
			if service.ShortAutogeneratedRouteDomain != "" && len(routeDomain) > 63 {
				ingress.Spec.TLS[0].Hosts = append(ingress.Spec.TLS[0].Hosts, service.ShortAutogeneratedRouteDomain)
			}
		}
	}
	// add the main domain to the tls spec now
	ingress.Spec.TLS[0].Hosts = append(ingress.Spec.TLS[0].Hosts, routeDomain)

	// default service port is http in all lagoon deployments
	servicePort := networkv1.ServiceBackendPort{
		Name: "http",
	}

	// if a port number is provided, use it
	if route.ServicePortNumber != nil {
		servicePort = networkv1.ServiceBackendPort{
			Number: *route.ServicePortNumber,
		}
	}
	// if a different port name is provided use it above all else
	if route.ServicePortName != nil {
		servicePort = networkv1.ServiceBackendPort{
			Name: *route.ServicePortName,
		}
	}

	// set up the pathtype prefix for the host rule
	pt := networkv1.PathTypePrefix
	// add the main domain as the first rule in the spec
	ingress.Spec.Rules = []networkv1.IngressRule{
		{
			Host: routeDomain,
			IngressRuleValue: networkv1.IngressRuleValue{
				HTTP: &networkv1.HTTPIngressRuleValue{
					Paths: []networkv1.HTTPIngressPath{
						{
							Path:     "/",
							PathType: &pt,
							Backend: networkv1.IngressBackend{
								Service: &networkv1.IngressServiceBackend{
									Name: route.LagoonService,
									Port: servicePort,
								},
							},
						},
					},
				},
			},
		},
	}
	// check if any alternative names were provided and add them to the spec
	for _, alternativeName := range route.AlternativeNames {
		ingress.Spec.TLS[0].Hosts = append(ingress.Spec.TLS[0].Hosts, alternativeName)
		altName := networkv1.IngressRule{
			Host: alternativeName,
			IngressRuleValue: networkv1.IngressRuleValue{
				HTTP: &networkv1.HTTPIngressRuleValue{
					Paths: []networkv1.HTTPIngressPath{
						{
							Path:     "/",
							PathType: &pt,
							Backend: networkv1.IngressBackend{
								Service: &networkv1.IngressServiceBackend{
									Name: route.LagoonService,
									Port: servicePort,
								},
							},
						},
					},
				},
			},
		}
		ingress.Spec.Rules = append(ingress.Spec.Rules, altName)
	}

	// @TODO: we should review this in the future when we stop doing `kubectl apply` in the builds :)
	// marshal the resulting ingress
	ingressBytes, err := yaml.Marshal(ingress)
	if err != nil {
		return nil, err
	}
	// add the seperator to the template so that it can be `kubectl apply` in bulk as part
	// of the current build process
	separator := []byte("---\n")
	result := append(separator[:], ingressBytes[:]...)
	return result, nil
}
