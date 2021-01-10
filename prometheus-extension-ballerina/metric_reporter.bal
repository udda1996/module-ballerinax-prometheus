// Copyright (c) 2020 WSO2 Inc. (http://www.wso2.org) All Rights Reserved.
//
// WSO2 Inc. licenses this file to you under the Apache License,
// Version 2.0 (the "License"); you may not use this file except
// in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

import ballerina/io;
import ballerina/config;
import ballerina/http;
import ballerina/lang.'string as str;
import ballerina/observe;
import ballerina/stringutils;
import ballerina/java as _;     // To allow packaging Java native code

const REPORTER_NAME = "prometheus";

const string OBSERVABILITY_METRICS_ENABLED_CONFIG = "b7a.observability.metrics.enabled";
final boolean OBSERVABILITY_METRICS_ENABLED = config:getAsBoolean(OBSERVABILITY_METRICS_ENABLED_CONFIG, false);

const string OBSERVABILITY_METRICS_REPORTER_NAME_CONFIG = "b7a.observability.metrics.reporter";
final string OBSERVABILITY_METRICS_REPORTER_NAME = config:getAsString(OBSERVABILITY_METRICS_REPORTER_NAME_CONFIG, REPORTER_NAME);

const string PROMETHEUS_PORT_CONFIG = "b7a.observability.metrics.prometheus.port";
final int REPORTER_PORT = config:getAsInt(PROMETHEUS_PORT_CONFIG, 9797);

const string PROMETHEUS_HOST_CONFIG = "b7a.observability.metrics.prometheus.host";
final string REPORTER_HOST = config:getAsString(PROMETHEUS_HOST_CONFIG, "0.0.0.0");

const string METRIC_TYPE_GAUGE = "gauge";
const string METRIC_TYPE_SUMMARY = "summary";
const string EMPTY_STRING = "";

const string EXPIRY_TAG = "timeWindow";
const string PERCENTILE_TAG = "quantile";

isolated function init() {
    if (OBSERVABILITY_METRICS_ENABLED && OBSERVABILITY_METRICS_REPORTER_NAME == REPORTER_NAME) {
        error? err = startReporter(REPORTER_HOST, REPORTER_PORT);
        if (err is error) {
            io:println("error: failed to start prometheus metrics reporter");
        } else {
            io:println("ballerina: enabled prometheus metrics reporter");
        }
    }
}

# Start a server to serve prometheus metrics.
isolated function startReporter(string host, int port) returns error? {
    http:Listener httpListener = new(port, config = {
        host: host
    });
    service object {} prometheusReporter =
        service object {
            # This method retrieves all metrics registered in the ballerina metrics registry,
            # and reformats based on the expected format by prometheus server.
            @http:ResourceConfig {
                produces: ["application/text"]
            }
            resource function get metrics(http:Caller caller, http:Request req) {
                observe:Metric?[] metrics = observe:getAllMetrics();
                string payload = EMPTY_STRING;
                foreach var m in metrics {
                    observe:Metric metric = <observe:Metric> m;
                    string qualifiedMetricName = getEscapedName(metric.name);
                    string metricReportName = getMetricName(qualifiedMetricName, "value");
                    payload += generateMetricHelp(metricReportName, metric.desc);
                    payload += generateMetricInfo(metricReportName, metric.metricType);
                    payload += generateMetric(metricReportName, metric.tags, metric.value);
                    if ((str:toLowerAscii(metric.metricType) == (METRIC_TYPE_GAUGE)) && metric.summary !== ()){
                        map<string> tags = metric.tags;
                        observe:Snapshot[]? summaries = metric.summary;
                        if (summaries is ()) {
                            payload += "\n";
                        } else {
                            foreach var aSnapshot in summaries {
                                tags[EXPIRY_TAG] = aSnapshot.timeWindow.toString();
                                payload += generateMetricHelp(qualifiedMetricName, "A Summary of " +  qualifiedMetricName + " for window of "
                                                            + aSnapshot.timeWindow.toString());
                                payload += generateMetricInfo(qualifiedMetricName, METRIC_TYPE_SUMMARY);
                                payload += generateMetric(getMetricName(qualifiedMetricName, "mean"), tags, aSnapshot.mean);
                                payload += generateMetric(getMetricName(qualifiedMetricName, "max"), tags, aSnapshot.max);
                                payload += generateMetric(getMetricName(qualifiedMetricName, "min"), tags, aSnapshot.min);
                                payload += generateMetric(getMetricName(qualifiedMetricName, "stdDev"), tags,
                                aSnapshot.stdDev);
                                foreach var percentileValue in aSnapshot.percentileValues  {
                                    tags[PERCENTILE_TAG] = percentileValue.percentile.toString();
                                    payload += generateMetric(qualifiedMetricName, tags, percentileValue.value);
                                }
                                _ = tags.remove(EXPIRY_TAG);
                                _ = tags.remove(PERCENTILE_TAG);
                            }
                        }
                    }
                }
                http:Response res = new;
                res.setPayload(payload);
                checkpanic caller->respond(res);
            }
        };
    check httpListener.attach(prometheusReporter, "/");
    check httpListener.start();
}

# This util function creates the type description based on the prometheus format for the specific metric.
#
# + name - Name of the Metric.
# + metricType - Type of Metric.
# + return - Formatted metric information.
isolated function generateMetricInfo(string name, string metricType) returns string {
    return "# TYPE " + name + " " + metricType + "\n";
}

# This util function creates the metric help description based on the prometheus format for the specific metric.
#
# + name - Name of the Metric.
# + description - Description of the Metric.
# + return - Formatted metric description information.
isolated function generateMetricHelp(string name, string description) returns string {
    if (description != EMPTY_STRING) {
        return "# HELP " + name + " " + description + "\n";
    }
    return EMPTY_STRING;
}

# This util function creates the metric along with its name, labels, and values based on the prometheus
# format for the specific metric.
#
# + name - Name of the Metric.
# + labels - Labels attached to the Metric.
# + value - Values attached to the Metric.
# + return - Formatted Metric.
isolated function generateMetric(string name, map<string>? labels, int|float value) returns string {
    string strValue = "";
    if (value is int) {
        strValue = value.toString() + ".0";
    } else {
        strValue = value.toString();
    }

    if (labels is map<string>) {
        string strLabels = getTagsString(labels);
        return (name + strLabels + " " + strValue + "\n");
    } else {
        return (name + " " + strValue + "\n");
    }
}

# Generate the prometheus tags string.
#
# + labels - map of labels to be converted to tags string
# + return - prometheus tags string
isolated function getTagsString(map<string> labels) returns string {
    string stringLabel = "{";
    foreach var [key, value] in labels.entries() {
        string labelKey = getEscapedName(key);
        string entry = labelKey + "=\"" + getEscapedLabelValue(value) + "\"";
        stringLabel += (entry + ",");
    }
    if (stringLabel != "{") {
        return (stringLabel + "}");
    } else {
        return "";
    }
}

# Only [a-zA-Z0-9:_] are valid in metric names, any other characters
# should be sanitized to an underscore. ref: Metrics Naming[1].
# [1] https://prometheus.io/docs/instrumenting/writing_exporters/#naming
#
# + str - string to be escaped.
# + return - escaped string.
isolated function getEscapedName(string str) returns string {
    return stringutils:replaceAll(str, "[^a-zA-Z0-9:_]", "_");
}

# Only [^a-zA-Z0-9\\/.:_* ] are valid in metric lable values, any other characters
# should be sanitized to an underscore.
#
# + str - string to be escaped.
# + return - escaped string.
isolated function getEscapedLabelValue(string str) returns string {
    return stringutils:replaceAll(str, "[^a-zA-Z0-9\\/.:_* ]", "_");
}

# Add the summary type name to summary type metrics.
#
# + name - name of the metric
# + summaryType - type of the summary metric
# + return - name of the summary type metric
isolated function getMetricName(string name, string summaryType) returns string {
    return name + "_" + summaryType;
}
